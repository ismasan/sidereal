# frozen_string_literal: true

require 'tmpdir'
require 'stringio'
require 'async'
require 'sidereal/cli/store'

CLIStorePlace = Sidereal::Message.define('cli_store.place') do
  attribute :sku, Sidereal::Types::String
end

CLIStoreCancel = Sidereal::Message.define('cli_store.cancel')

RSpec.describe Sidereal::CLI::StoreCommand do
  around do |example|
    pwd = Dir.pwd
    # Under /tmp: the pubsub's socket path has to fit a sockaddr_un.
    Dir.mktmpdir(['sid-store-', ''], '/tmp') do |dir|
      @dir = dir
      example.run
    end
  ensure
    Dir.chdir(pwd)
  end

  after { %w[console commands db sourced system skills store].each { |name| Sidereal::CLI.registry.delete(name) } }

  # Enough for CLI.load_app: it chdirs in and requires boot.rb.
  def app!(body = "Sidereal.config.use_file_system!\n")
    File.write(File.join(@dir, 'Gemfile'), "source 'https://rubygems.org'\n\ngem 'sidereal'\n")
    File.write(File.join(@dir, 'boot.rb'), "require 'sidereal'\n#{body}")
    Sidereal::CLI.load_app(@dir)
    @dir
  end

  def sid(*arguments)
    out = StringIO.new
    Sidereal::CLI::Application.new(arguments, name: 'sid', output: out).call
    out.string
  end

  # The app's store, as another process writing to it sees it.
  def store = @store ||= Sidereal::Store::FileSystem.new(root: File.join(@dir, 'storage', 'store'))

  def append(message)
    store.append(message)
    message
  end

  # Append a message and have a worker fail it for good.
  def dead_letter!(message, error: RuntimeError.new('boom'))
    append(message)
    # A store's poller lives in the task it started in, so each run of
    # workers needs a store of its own.
    worker = Sidereal::Store::FileSystem.new(root: File.join(@dir, 'storage', 'store'), poll_interval: 0.01)
    Sync do |task|
      worker.start(task)
      failed = false
      consumer = task.async do
        worker.claim_next do |_message, _meta|
          failed = true
          Sidereal::Store::Result::Fail.new(error:)
        end
      end
      sleep 0.01 until failed && store.entries(:processing).empty?
      consumer.stop
    end
    message
  end

  before { app! }

  describe 'stats' do
    it 'counts the messages in each queue' do
      # First: the worker that fails it would take any ready message.
      dead_letter!(CLIStoreCancel.new)
      append(CLIStorePlace.new(payload: { sku: 'a' }))
      append(CLIStorePlace.new(payload: { sku: 'b' }, created_at: Time.now + 600))

      out = sid('store', 'stats')

      expect(out).to match(/^ready\s+1\b/)
      expect(out).to match(/^scheduled\s+1\s+\S+\s+in (9|10)m$/)
      expect(out).to match(/^processing\s+0$/)
      expect(out).to match(/^dead\s+1\b/)
    end
  end

  describe 'list' do
    it 'lists every queue, with why each dead letter failed' do
      dead = dead_letter!(CLIStoreCancel.new, error: ArgumentError.new("no such order\nmore detail"))
      ready = append(CLIStorePlace.new(payload: { sku: 'a' }))
      scheduled = append(CLIStorePlace.new(payload: { sku: 'b' }, created_at: Time.now + 600))

      out = sid('store', 'list')

      expect(out).to match(/^#{ready.id}\s+cli_store\.place\s+ready\s+1\s+\d+s$/)
      expect(out).to match(/^#{scheduled.id}\s+cli_store\.place\s+scheduled\s+1\s+\d+s\s+due in (9|10)m$/)
      expect(out).to match(/^#{dead.id}\s+cli_store\.cancel\s+dead\s+1\s+\d+s\s+ArgumentError: no such order$/)
    end

    it 'narrows to --queue and --type' do
      dead_place = dead_letter!(CLIStorePlace.new(payload: { sku: 'x' }))
      dead_cancel = dead_letter!(CLIStoreCancel.new)
      append(CLIStorePlace.new(payload: { sku: 'a' }))

      out = sid('store', 'list', '--queue', 'dead', '--type', 'cli_store.place')

      expect(out).to include(dead_place.id)
      expect(out).not_to include(dead_cancel.id, ' ready ')
      expect(sid('store', 'list', '--type', 'cli_store.*').lines.size).to eq(4)
    end

    it 'says how many it left out under --limit' do
      3.times { |i| append(CLIStorePlace.new(payload: { sku: i.to_s })) }

      out = nil
      expect { out = sid('store', 'list', '--limit', '2') }.to output(/Showing 2 of 3/).to_stderr
      expect(out.lines.size).to eq(3)
    end

    it 'says when there is nothing to list' do
      expect(sid('store', 'list', '--queue', 'dead')).to eq("No messages in dead.\n")
    end

    it 'rejects an unknown queue' do
      expect { sid('store', 'list', '--queue', 'archive') }.to raise_error(Sidereal::CLI::Error, /Unknown queue archive/)
    end
  end

  describe 'show' do
    it "shows a dead letter's payload and error, by the start of its id" do
      dead = dead_letter!(CLIStorePlace.new(payload: { sku: 'x1' }), error: RuntimeError.new('out of stock'))

      out = sid('store', 'show', dead.id[0, 8])

      expect(out).to start_with("cli_store.place  #{dead.id}\n")
      expect(out).to match(/^Queue\s+dead$/)
      expect(out).to include(%("sku": "x1"))
      expect(out).to include('RuntimeError: out of stock')
    end

    it 'prints JSON with --json' do
      dead = dead_letter!(CLIStoreCancel.new, error: RuntimeError.new('nope'))

      json = JSON.parse(sid('store', 'show', dead.id, '--json'))

      expect(json).to include('queue' => 'dead', 'attempt' => 1)
      expect(json['message']).to include('id' => dead.id, 'type' => 'cli_store.cancel')
      expect(json['error']).to include('class' => 'RuntimeError', 'message' => 'nope')
    end

    it 'finds a message by its filename' do
      message = append(CLIStorePlace.new(payload: { sku: 'a' }))
      name = store.entries(:ready).first.name

      expect(sid('store', 'show', "storage/store/ready/#{name}")).to include(message.id)
    end

    it 'shows a message whose type the app no longer defines' do
      append(CLIStorePlace.new(payload: { sku: 'a' }))
      entry = store.entries(:ready).first
      File.write(entry.path, File.read(entry.path).sub('cli_store.place', 'cli_store.removed'))

      expect(sid('store', 'show', entry.name)).to start_with('cli_store.removed')
    end

    it 'raises for a message it cannot find' do
      expect { sid('store', 'show', 'nope') }.to raise_error(Sidereal::CLI::Error, /No message nope/)
    end
  end

  describe 'requeue' do
    it 'moves the dead letters named back to ready' do
      first = dead_letter!(CLIStorePlace.new(payload: { sku: 'a' }))
      second = dead_letter!(CLIStorePlace.new(payload: { sku: 'b' }))

      out = sid('store', 'requeue', first.id)

      expect(out).to include("requeue  #{first.id}  cli_store.place")
      expect(store.entries(:ready).map { |entry| store.read(entry)['id'] }).to eq([first.id])
      expect(store.entries(:dead).map { |entry| store.read(entry)['id'] }).to eq([second.id])
    end

    it 'requeues every dead letter of a type with --all --type' do
      place = dead_letter!(CLIStorePlace.new(payload: { sku: 'a' }))
      cancel = dead_letter!(CLIStoreCancel.new)

      sid('store', 'requeue', '--all', '--type', 'cli_store.place')

      expect(store.entries(:ready).map { |entry| store.read(entry)['id'] }).to eq([place.id])
      expect(store.entries(:dead).map { |entry| store.read(entry)['id'] }).to eq([cancel.id])
    end

    it 'only looks for dead letters' do
      ready = append(CLIStorePlace.new(payload: { sku: 'a' }))

      expect { sid('store', 'requeue', ready.id) }.to raise_error(Sidereal::CLI::Error, /No message .* in dead/)
    end

    it 'needs ids or --all' do
      expect { sid('store', 'requeue') }.to raise_error(Sidereal::CLI::Error, /or pass --all/)
    end
  end

  describe 'delete' do
    it 'deletes a scheduled message by id' do
      scheduled = append(CLIStorePlace.new(payload: { sku: 'a' }, created_at: Time.now + 600))

      expect(sid('store', 'delete', scheduled.id)).to include("delete  #{scheduled.id}  cli_store.place  (scheduled)")
      expect(store.entries(:scheduled)).to be_empty
    end

    it 'refuses a message being handled, and deletes nothing' do
      ready = append(CLIStorePlace.new(payload: { sku: 'a' }))
      worker = Sidereal::Store::FileSystem.new(root: File.join(@dir, 'storage', 'store'), poll_interval: 0.01)
      error = nil
      Sync do |task|
        worker.start(task)
        handled = false
        consumer = task.async do
          worker.claim_next do |_message, _meta|
            begin
              sid('store', 'delete', ready.id)
            rescue Sidereal::CLI::Error => e
              error = e
            end
            handled = true
            Sidereal::Store::Result::Ack
          end
        end
        sleep 0.01 until handled && store.entries(:processing).empty?
        consumer.stop
      end

      expect(error&.message).to match(/being handled right now/)
    end

    it 'deletes every dead letter with --all, and nothing else' do
      dead_letter!(CLIStorePlace.new(payload: { sku: 'a' }))
      dead_letter!(CLIStoreCancel.new)
      append(CLIStorePlace.new(payload: { sku: 'b' }))

      sid('store', 'delete', '--all')

      expect(Dir.children(File.join(@dir, 'storage', 'store', 'dead'))).to be_empty
      expect(store.entries(:ready).size).to eq(1)
    end
  end

  describe 'in an app whose store something else replaced' do
    # boot.rb is required by its path, so the second app needs its own.
    def replaced_app!(body)
      @dir = File.join(@dir, 'replaced').tap { |dir| Dir.mkdir(dir) }
      app!(body)
    end

    def not_offered!
      io = StringIO.new
      expect(Sidereal::CLI::Application.call(%w[store list], output: io)).to be(false)
      expect(io.string).to include('Could not parse token "store"')
    end

    it 'is not offered when an integration used later implements the store' do
      replaced_app!(<<~RUBY)
        module ReplacingIntegration
          def self.setup(config) = config.config!('sidereal.store') { Sidereal::Store::Memory.instance }
        end
        Sidereal.config.use_file_system!
        Sidereal.config.use ReplacingIntegration
      RUBY

      not_offered!
    end

    it 'is not offered when the app implements the store itself' do
      replaced_app!(<<~RUBY)
        Sidereal.config.use_file_system!
        Sidereal.config.config!('sidereal.store') { Sidereal::Store::Memory.instance }
      RUBY

      not_offered!
    end
  end
end
