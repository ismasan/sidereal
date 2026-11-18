# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'tmpdir'
require 'zeitwerk'
require 'sourced'
require 'sidereal/integrations/sourced'

RsyncThing = Sourced::Event.define('rsync.thing') { attribute :thing_id, String }

RSpec.describe Sidereal::Integrations::Sourced::ReactorSync do
  let(:registry) { Sourced::Registry.new }
  let(:changes) { [] }
  let(:source) { Object.new }
  let(:other_source) { Object.new }

  subject(:sync) { described_class.new(registry:, after_change: -> { changes << registry.reactors }) }

  def reactor(group_id, handles: [RsyncThing])
    Class.new do
      extend Sourced::Consumer

      partition_by :thing_id
      define_singleton_method(:group_id) { group_id }
      define_singleton_method(:handled_messages) { handles }
      def self.handle_claim(claim) = claim.messages.map { |m| [[], m] }
    end
  end

  it "registers the reactors among the constants, and skips commanders and reactors that handle no messages" do
    todos = reactor('rsync.todos')
    commander = Class.new(Sidereal::Commander)
    abstract = Class.new(Sourced::Decider)

    sync.call(source, [Module.new, RsyncThing, 'a string', todos, commander, abstract])

    expect(registry.reactors).to eq([todos])
    expect(sync.reactors(source)).to eq([todos])
    expect(changes).to eq([[todos]])
  end

  it "replaces a source's reactors with the ones its next scan finds, and keeps other sources'" do
    old_todos = reactor('rsync.todos')
    lists = reactor('rsync.lists')
    other = reactor('rsync.other')
    sync.call(source, [old_todos, lists])
    sync.call(other_source, [other])

    new_todos = reactor('rsync.todos')
    sync.call(source, [new_todos])

    expect(registry.reactors).to eq([other, new_todos])
    expect(sync.reactors(source)).to eq([new_todos])
  end

  it "replaces a reactor registered before the source's first scan" do
    old_todos = reactor('rsync.todos')
    registry.register(old_todos)
    sync.call(source, [old_todos])

    new_todos = reactor('rsync.todos')
    sync.call(source, [new_todos])

    expect(registry.reactors).to eq([new_todos])
  end

  it 'raises for an invalid set, and leaves the registry and its record as they were' do
    todos = reactor('rsync.todos')
    sync.call(source, [todos])

    expect { sync.call(source, [reactor('rsync.todos'), reactor('rsync.todos')]) }
      .to raise_error(ArgumentError, /already uses group_id "rsync.todos"/)
    expect(registry.reactors).to eq([todos])
    expect(sync.reactors(source)).to eq([todos])
    expect(changes.size).to eq(1)
  end

  it 'keeps the reactors found when a registry listener raises, so the next scan replaces them' do
    sync.call(source, [reactor('rsync.todos')])
    failing = true
    registry.on_change do
      if failing
        failing = false
        raise 'listener'
      end
    end

    second = reactor('rsync.todos')
    expect { sync.call(source, [second]) }.to raise_error(RuntimeError, 'listener')
    expect(sync.reactors(source)).to eq([second])
    expect(changes.last).to eq([second])

    third = reactor('rsync.todos')
    sync.call(source, [third])

    expect(registry.reactors).to eq([third])
  end
end

# What the reloaded deciders handled. Out here, where reloading can't reset it.
RSYNC_HANDLED = []

RSpec.describe Sidereal::Integrations::Sourced, 'registering the reactors from_dir loads' do
  let(:root) { Dir.mktmpdir }
  let(:system) { File.join(root, 'system') }
  let(:config) { Sidereal.config }
  let(:errors) { [] }
  let(:loader) do
    Zeitwerk::Loader.new.tap do |l|
      l.push_dir(system)
      l.enable_reloading
    end
  end

  def write_courses(version, delay: 0)
    File.write(File.join(system, 'rsync_courses.rb'), <<~RUBY)
      class RsyncCourses < Sourced::Decider
        Create = Sourced::Command.define('rsync.courses.create') { attribute :course_id, String }
        Created = Sourced::Event.define('rsync.courses.created') { attribute :course_id, String }

        partition_by :course_id

        command Create => Created do |_, cmd|
          sleep #{delay}
          RSYNC_HANDLED << "#{version} \#{cmd.payload.course_id}"
          event Created, course_id: cmd.payload.course_id
        end
      end
    RUBY
  end

  def use_sourced(**opts)
    config.loader = loader
    config.from_dir(File.join(system, '**/*.rb'), root: system, on_error: ->(e) { errors << e })
    database = Sequel.sqlite(File.join(root, 'app.db'))
    config.declare('db', Sequel::Database)
    config.config!('db') { database }
    config.use(Sidereal::Integrations::Sourced, db: 'db', **opts)
    config.config!('sourced.logger') { Sourced::NULL_LOGGER }
    config.config!('sourced.store.install_tables') { true }
    loader.setup
  end

  def courses = Object.const_get('RsyncCourses')

  before do
    Sourced.reset!
    RSYNC_HANDLED.clear
    FileUtils.mkdir_p(system)
    write_courses('v1')
  end

  after do
    config.teardown! if %i[built started].include?(config.boot_status)
    loader.unload
    loader.unregister
    FileUtils.rm_rf(root)
  end

  it 'registers them when the directories install' do
    use_sourced
    config.install_dirs!

    expect(Sourced.registry.reactors).to eq([courses])

    config.build!

    expect(Sourced.router.reactors).to include(courses)
  end

  it 'raises when applied after the directories installed, which it would miss' do
    config.loader = loader
    config.from_dir(File.join(system, '**/*.rb'), root: system)
    loader.setup
    config.install_dirs!

    expect { config.use(Sidereal::Integrations::Sourced) }.to raise_error(ArgumentError, /already installed/)
  end

  it "doesn't with reactors: false" do
    use_sourced(reactors: false)
    config.build!

    expect(Sourced.registry.reactors).to eq([])
  end

  it 'routes to the reloaded reactors, and decodes into the reloaded messages, after a reload' do
    use_sourced
    config.build!
    Sidereal.message_codec.compile!
    old = courses

    loader.reload
    message = courses::Created.new(payload: { course_id: 'c1' })

    expect(courses).not_to be(old)
    expect(Sourced.router.reactors).to include(courses)
    expect(Sourced.router.reactors).not_to include(old)
    [config['sourced.store.codec'], Sidereal.message_codec].each do |codec|
      expect(codec.decode(codec.encode(message))).to be_a(courses::Created)
    end
  end

  it 'leaves the reactors as they were when a file is broken' do
    use_sourced
    config.build!
    old = courses

    File.write(File.join(system, 'rsync_courses.rb'), "class RsyncCourses < Sourced::Decider\n  def oops(\nend")
    loader.reload

    expect(errors.map(&:class)).to eq([SyntaxError])
    expect(Sourced.router.reactors).to include(old)
  end

  it "handles commands with the reloaded reactors in a started app, on the runner's dispatcher" do
    elector = Class.new do
      include Sidereal::Elector::Callbacks
      define_method(:leader?) { true }
      define_method(:start) { |_task| self }
      public :promote!, :demote!
    end.new
    use_sourced
    config.config!('sidereal.elector') { elector }
    config.config!('sourced.workers.count') { 1 }
    config.config!('sourced.workers.catchup_interval') { 0.05 }
    handled = lambda do |entry|
      Timeout.timeout(3) { sleep 0.02 until RSYNC_HANDLED.include?(entry) }
      RSYNC_HANDLED
    end

    Sync do |task|
      config.start!(task)
      elector.promote!
      Sidereal.store.append(courses::Create.new(payload: { course_id: 'c1' }))
      expect(handled.('v1 c1')).to eq(['v1 c1'])

      write_courses('v2')
      task.async { loader.reload }.wait
      Sidereal.store.append(courses::Create.new(payload: { course_id: 'c2' }))

      expect(handled.('v2 c2')).to eq(['v1 c1', 'v2 c2'])
      expect(config['sourced.dispatcher']).to be_running

      # Pending across a reload, while the dispatcher is stopped
      elector.demote!
      Sidereal.store.append(courses::Create.new(payload: { course_id: 'c3' }))
      write_courses('v3')
      loader.reload
      elector.promote!

      expect(handled.('v3 c3')).to eq(['v1 c1', 'v2 c2', 'v3 c3'])
    ensure
      config.teardown!
    end
  end

  it 'handles every command pending while the running dispatcher reloads, with one version or the other' do
    elector = Class.new do
      include Sidereal::Elector::Callbacks
      define_method(:leader?) { true }
      define_method(:start) { |_task| self }
      public :promote!
    end.new
    use_sourced
    config.config!('sidereal.elector') { elector }
    config.config!('sourced.workers.count') { 2 }
    config.config!('sourced.workers.batch_size') { 1 }
    config.config!('sourced.workers.catchup_interval') { 0.05 }
    ids = (1..40).map { |i| "p#{i}" }

    Sync do |task|
      config.start!(task)
      elector.promote!
      write_courses('v1', delay: 0.005)
      loader.reload
      create = courses::Create
      Sidereal.store.append(ids.map { |id| create.new(payload: { course_id: id }) })
      write_courses('v2')
      sleep 0.01 until RSYNC_HANDLED.any? # the workers are on the backlog
      loader.reload

      Timeout.timeout(5) { sleep 0.02 until RSYNC_HANDLED.size >= ids.size }
      sleep 0.2 # anything handled twice, or acked without handling, would show by now

      expect(RSYNC_HANDLED.map { |e| e.split.last }.sort).to eq(ids.sort)
      expect(RSYNC_HANDLED.map { |e| e.split.first }.uniq - %w[v1 v2]).to eq([])
    ensure
      config.teardown!
    end
  end
end
