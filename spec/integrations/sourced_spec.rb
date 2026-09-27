# frozen_string_literal: true

require 'spec_helper'
require 'sourced'
require 'sourced/store'
require 'sourced/testing/rspec'
require 'sidereal/integrations/sourced'

# -- Test messages --

IntgDoThing = Sidereal::Message.define('intg.do_thing') do
  attribute :n, Sidereal::Types::Integer
end

IntgScheduleThing = Sidereal::Message.define('intg.schedule_thing') do
  attribute :n, Sidereal::Types::Integer
end

IntgDoNext = Sidereal::Message.define('intg.do_next') do
  attribute :n, Sidereal::Types::Integer
end

IntgThingHappened = Sidereal::Message.define('intg.thing_happened') do
  attribute :n, Sidereal::Types::Integer
end

class IntgCommander < Sidereal::Commander
  command IntgDoThing do |cmd|
    dispatch IntgDoNext, n: cmd.payload.n          # follow-up command (in registry)
    dispatch IntgThingHappened, n: cmd.payload.n   # event (not in registry) -> Result.events
  end

  command IntgScheduleThing do |cmd|
    dispatch(IntgDoNext, n: cmd.payload.n).in(3600) # delayed follow-up
  end

  command IntgDoNext do |_cmd|
    # terminal, no-op
  end
end

class IntgFakePubSub
  attr_reader :published

  def initialize
    @published = []
  end

  def start(_task) = self
  def subscribe(_pattern) = nil

  def publish(channel, message)
    @published << { channel: channel, message: message }
    self
  end
end

# -- Test Sourced reactors (Decider + Projectors) exercising the integration's
#    auto-publish hooks. Defined after `require 'sidereal/integrations/sourced'`,
#    so the Decider inherits the injected after_sync and the Projectors trigger
#    the partition_by signal-generation hook. --

class IntgWidget < Sourced::Decider
  consumer_group 'intg_widget'
  partition_by :widget_id

  Create  = Sourced::Command.define('intg_widget.create') { attribute :widget_id, Sourced::Types::String }
  Created = Sourced::Event.define('intg_widget.created')  { attribute :widget_id, Sourced::Types::String }

  state do |init|
    { widget_id: init[:widget_id], created: false }
  end

  evolve(Created) do |state, _evt|
    state[:created] = true
  end

  command(Create) do |_state, cmd|
    event Created, widget_id: cmd.payload.widget_id
  end
end

IntgThingHappenedEvt = Sourced::Event.define('intg.thing_happened_evt') do
  attribute :thing_id, Sourced::Types::String
end

# Single partition key.
class IntgThingProjector < Sourced::Projector::StateStored
  consumer_group 'intg_thing_projector'
  partition_by :thing_id

  state do |values|
    { thing_id: values[:thing_id] }
  end

  evolve(IntgThingHappenedEvt) do |state, evt|
    state[:thing_id] = evt.payload.thing_id
  end
end

IntgEnrolledEvt = Sourced::Event.define('intg.enrolled') do
  attribute :student_id, Sourced::Types::String
  attribute :course_id, Sourced::Types::String
end

# Multiple partition keys (student_id + course_id).
class IntgEnrollmentProjector < Sourced::Projector::StateStored
  consumer_group 'intg_enrollment_projector'
  partition_by :student_id, :course_id

  # Deliberately keeps course_id OUT of state — the Projected signal must
  # still carry it (sourced from partition_values, not read-model state).
  state do |values|
    { student_id: values[:student_id] }
  end

  evolve(IntgEnrolledEvt) do |state, evt|
    state[:student_id] = evt.payload.student_id
  end
end

RSpec.describe 'Sidereal::Commander on the Sourced runtime' do
  let(:db) { Sequel.sqlite }
  let(:store) { Sourced::Store.new(db) }
  let(:router) { Sourced::Router.new(store: store) }
  let(:pubsub) { IntgFakePubSub.new }

  before do
    Sidereal.config.config!('sidereal.pubsub') { pubsub }
    # For 'dep in Sourced reactors'. Declared here: the config is built below,
    # and locked from then on.
    Sidereal.config.declare('naming') { ->(id) { "named-#{id}" } }
    Sidereal.config.build!
    # setup! creates the tables and compiles the store's message codec, which
    # serializes payloads on #append.
    store.setup!
    router.register(IntgCommander)
  end

  after do
    # These specs open in-memory SQLite via Sequel; Sequel::DATABASES keeps a
    # global ref so the connection stays open. Close them after each example so
    # the fork-based specs (pubsub/unix_failover, store/file_system) don't inherit
    # a live SQLite connection and trip sqlite3's fork-safety warning.
    Sequel::DATABASES.each(&:disconnect)
  end

  it 'registers a Commander as an exclusive, id-partitioned Sourced reactor' do
    expect(IntgCommander.exclusive?).to be true
    expect(IntgCommander.handled_messages).to include(IntgDoThing, IntgDoNext)

    row = db[:sourced_consumer_groups].where(group_id: 'IntgCommander').first
    expect(JSON.parse(row[:partition_by])).to eq(['__id'])
  end

  describe Sidereal::Integrations::Sourced::Notifier do
    let(:memory_pubsub) { Sidereal::PubSub::Memory.new }
    subject(:notifier) { described_class.new(pubsub: memory_pubsub, exceptions: Sidereal.exceptions) }

    def with_listener(notifier)
      Sync do |task|
        listener = task.async { notifier.start }
        sleep 0.01 # let the listener subscribe before anything is announced
        yield
        sleep 0.05
        notifier.stop
        listener.wait
      end
    end

    it 'forwards store announcements to its subscribers through the pubsub' do
      received = []
      notifier.subscribe(->(event, value) { received << [event, value] })

      with_listener(notifier) do
        notifier.notify_new_messages(%w[a b a])
        notifier.notify_reactor_resumed('g')
      end

      expect(received).to eq([['messages_appended', 'a,b'], ['reactor_resumed', 'g']])
    end

    it 'wakes a subscriber when its store appends' do
      notified_store = Sourced::Store.new(db, notifier:)
      received = []
      notifier.subscribe(->(event, value) { received << [event, value] })

      with_listener(notifier) do
        notified_store.append(IntgDoThing.new(payload: { n: 1 }))
      end

      expect(received).to eq([['messages_appended', 'intg.do_thing']])
    end

    it 'keeps forwarding to its subscribers when started again after stopping' do
      received = []
      notifier.subscribe(->(event, value) { received << [event, value] })
      with_listener(notifier) {}

      with_listener(notifier) { notifier.notify_new_messages(['x']) }

      expect(received).to eq([['messages_appended', 'x']])
    end

    it 'reports a failed publish as fatal instead of raising into the append' do
      broken = Class.new(IntgFakePubSub) do
        def publish(*) = raise('socket gone')
      end.new
      fatals = []
      Sidereal.exceptions.on_fatal { |report| fatals << report }
      notifier = described_class.new(pubsub: broken, exceptions: Sidereal.exceptions)

      expect { notifier.notify_new_messages(['x']) }.not_to raise_error
      expect(fatals.map { |r| r.exception.message }).to eq(['socket gone'])
    end
  end

  it 'handles a command: deletes it, appends the follow-up, publishes msg + events' do
    store.append(IntgDoThing.new(payload: { n: 1 }))

    expect(router.handle_next_for(IntgCommander)).to be true

    # handled command deleted (queue semantics)
    expect(db[:sourced_messages].where(message_type: 'intg.do_thing').count).to eq(0)
    # dispatched follow-up command appended
    expect(db[:sourced_messages].where(message_type: 'intg.do_next').count).to eq(1)
    # command + event published to Sidereal pubsub after commit
    published_types = pubsub.published.map { |p| p[:message].type }
    expect(published_types).to include('intg.do_thing', 'intg.thing_happened')

    # the follow-up command is itself claimable (id-indexed) and processed next
    expect(router.handle_next_for(IntgCommander)).to be true
    expect(db[:sourced_messages].count).to eq(0)
  end

  it 'schedules a delayed follow-up command (.in/.at) into scheduled_messages' do
    store.append(IntgScheduleThing.new(payload: { n: 2 }))

    expect(router.handle_next_for(IntgCommander)).to be true

    expect(db[:sourced_messages].where(message_type: 'intg.schedule_thing').count).to eq(0)
    expect(db[:sourced_messages].where(message_type: 'intg.do_next').count).to eq(0) # not appended yet
    expect(db[:sourced_scheduled_messages].count).to eq(1)                            # scheduled instead
  end

  # -- Auto-publish injected by the Sourced integration --

  describe 'dep in Sourced reactors' do
    include Sourced::Testing::RSpec

    it "injects into a decider, for its command blocks" do
      stub_const('IntgDepWidget', Class.new(Sourced::Decider) do
        consumer_group 'intg_dep_widget'
        partition_by :widget_id
        dep :naming

        command(IntgWidget::Create) do |_state, cmd|
          event IntgWidget::Created, widget_id: naming.call(cmd.payload.widget_id)
        end
      end)

      with_reactor(IntgDepWidget, widget_id: 'w1')
        .when(IntgWidget::Create, widget_id: 'w1')
        .then(IntgWidget::Created, widget_id: 'named-w1')
    end

    it 'injects into a projector, for its state and evolve blocks' do
      stub_const('IntgDepProjector', Class.new(Sourced::Projector::StateStored) do
        consumer_group 'intg_dep_projector'
        partition_by :thing_id
        dep 'naming' => 'namer'

        state do |values|
          { thing_id: values[:thing_id], label: namer.call(values[:thing_id]) }
        end

        evolve(IntgThingHappenedEvt) do |state, _evt|
          state[:seen] = true
        end
      end)

      with_reactor(IntgDepProjector, thing_id: 't1')
        .given(IntgThingHappenedEvt, thing_id: 't1')
        .then { |result| expect(result.state).to eq(thing_id: 't1', label: 'named-t1', seen: true) }
    end
  end

  describe 'sidereal_events for Page.on' do
    it 'a decider stands for the events it evolves' do
      expect(IntgWidget.sidereal_events).to eq(IntgWidget.handled_messages_for_evolve)
      expect(IntgWidget.sidereal_events).to include(IntgWidget::Created)
    end

    it 'a projector stands for its Projected signal' do
      expect(IntgThingProjector.sidereal_events).to eq([IntgThingProjector::Projected])
    end

    it 'lets a page react to a whole reactor' do
      page = Class.new(Sidereal::Page) { on IntgWidget, IntgThingProjector }

      expect(page.correlation_types).to include(IntgWidget::Created.type, IntgThingProjector::Projected.type)
    end
  end

  it 'registers the sidereal-sourced skill' do
    skill = File.read(File.join(Sidereal.skills['sidereal-sourced'], 'SKILL.md'))

    expect(skill).to include('name: sidereal-sourced', 'bin/sid sourced topology')
  end

  describe 'Sourced::Decider auto-publishes emitted events' do
    include Sourced::Testing::RSpec

    # Resolvers go on the global channels registry, which the suite empties
    # before each example — so nothing leaks between them, and a booted Host's
    # lock never bites here.
    it 'publishes each emitted event via Sidereal.channels.for — with no manual after_sync' do
      Sidereal.channels.channel_name(IntgWidget::Created) { |m| "widgets.#{m.payload.widget_id}" }

      # .then! (no block) runs Sync/AfterSync exactly once.
      with_reactor(IntgWidget, widget_id: 'w1')
        .when(IntgWidget::Create, widget_id: 'w1')
        .then!(IntgWidget::Created, widget_id: 'w1')

      expect(pubsub.published.size).to eq(1)
      entry = pubsub.published.first
      expect(entry[:channel]).to eq('widgets.w1')
      expect(entry[:message]).to be_a(IntgWidget::Created)
      expect(entry[:message].payload.widget_id).to eq('w1')
    end

    it 'publishes events correlated to the command, as they are stored' do
      with_reactor(IntgWidget, widget_id: 'w2')
        .when(IntgWidget::Create, widget_id: 'w2')
        .then!(IntgWidget::Created, widget_id: 'w2')

      event = pubsub.published.first[:message]
      expect(event.correlation_type).to eq(IntgWidget::Create.type)
      expect(event.causation_id).not_to eq(event.id)
      expect(event.correlation_id).to eq(event.causation_id)
    end
  end

  describe 'Sourced::Projector auto-generates + publishes a Projected signal' do
    include Sourced::Testing::RSpec

    # Auto-defines MyProjector::Projected (single key) and publishes it end-to-end.
    it 'publishes the Projected signal on the resolved channel after a batch' do
      Sidereal.channels.channel_name(IntgThingProjector::Projected) { |m| "things.#{m.payload.thing_id}" }

      with_reactor(IntgThingProjector, thing_id: 't1')
        .given(IntgThingHappenedEvt, thing_id: 't1')
        .then!([])

      expect(pubsub.published.size).to eq(1)
      entry = pubsub.published.first
      expect(entry[:channel]).to eq('things.t1')
      expect(entry[:message]).to be_a(IntgThingProjector::Projected)
      expect(entry[:message].payload.thing_id).to eq('t1')
    end

    it 'correlates the signal from the batch message so pages can match its root command' do
      with_reactor(IntgThingProjector, thing_id: 't2')
        .given(IntgThingHappenedEvt, thing_id: 't2')
        .then!([])

      signal = pubsub.published.first[:message]
      expect(signal.correlation_type).to eq(IntgThingHappenedEvt.type)
      expect(signal.causation_id).not_to eq(signal.id)
    end

    it 'publishes one signal per causal root in a batch, each from the last message of that root' do
      cmd_a = IntgDoThing.new(payload: { n: 1 })
      cmd_b = IntgDoThing.new(payload: { n: 2 })
      a1 = cmd_a.correlate(IntgThingHappenedEvt.new(payload: { thing_id: 't3' }))
      b1 = cmd_b.with_metadata(correlation_type: 'other.root')
                .correlate(IntgThingHappenedEvt.new(payload: { thing_id: 't3' }))
      a2 = cmd_a.correlate(IntgThingHappenedEvt.new(payload: { thing_id: 't3' }))
      batch = [a1, b1, a2].each_with_index.map { |m, i| Sourced::PositionedMessage.new(m, i + 1) }

      pairs = IntgThingProjector.handle_batch({ thing_id: 't3' }, batch)
      pairs.flat_map(&:first).select { |a| a.is_a?(Sourced::Actions::AfterSync) }.each { |a| a.work.call }

      signals = pubsub.published.map { |p| p[:message] }
      expect(signals.map(&:correlation_type)).to contain_exactly(IntgDoThing.type, 'other.root')
      by_root = signals.to_h { |sg| [sg.correlation_type, sg] }
      expect(by_root[IntgDoThing.type].causation_id).to eq(a2.id)
      expect(by_root['other.root'].causation_id).to eq(b1.id)
      expect(signals.map { |sg| sg.payload.thing_id }.uniq).to eq(['t3'])
    end

    it 'carries every key for a multi-key partition (partition_values, not read-model state)' do
      # The projector's evolve only writes student_id into state — the published
      # signal still carries BOTH keys, proving the payload comes from
      # partition_values rather than read-model state.
      Sidereal.channels.channel_name(IntgEnrollmentProjector::Projected) do |m|
        "enroll.#{m.payload.student_id}.#{m.payload.course_id}"
      end

      with_reactor(IntgEnrollmentProjector, student_id: 's1', course_id: 'c1')
        .given(IntgEnrolledEvt, student_id: 's1', course_id: 'c1')
        .then!([])

      expect(pubsub.published.size).to eq(1)
      entry = pubsub.published.first
      expect(entry[:channel]).to eq('enroll.s1.c1')
      expect(entry[:message].payload.to_h).to include(student_id: 's1', course_id: 'c1')
    end
  end
end

RSpec.describe 'Sidereal.config.use(Sidereal::Integrations::Sourced)' do
  let(:config) { Sidereal.config }
  let(:db) { Sequel.sqlite }

  # Sourced.config is process-global, and mounted into Sidereal.config, which
  # the suite replaces before each example: a fresh one can be mounted again.
  # So is the store's codec, which other examples have compiled already.
  before do
    Sourced.reset!
    Sourced::Store::MessageCodec.reset!
  end

  after do
    Sourced.reset!
    Sequel::DATABASES.each(&:disconnect)
  end

  def use_sourced
    database = db
    config.declare('db', Sequel::Database)
    config.config!('db') { database }
    config.use(Sidereal::Integrations::Sourced, db: 'db').tap do
      config.config!('sourced.logger') { Sourced::NULL_LOGGER }
    end
  end

  it "mounts Sourced's configuration at sourced, and appends commands to its store" do
    expect(use_sourced).to be(config)
    config.build!

    expect(config.node('sourced')).to be(Sourced.config)
    expect(Sidereal.store).to be(Sourced.store)
  end

  it "keeps Sourced's messages in the component named by db:" do
    use_sourced
    config.build!

    expect(Sourced.store.db).to be(db)
  end

  it 'announces appends through a Notifier over sidereal.pubsub' do
    use_sourced
    config.build!

    expect(config['sourced.notifier']).to be_a(Sidereal::Integrations::Sourced::Notifier)
    expect(Sourced.store.notifier).to be(config['sourced.notifier'])
  end

  it 'pins the dispatcher to the elected leader, overridable afterwards' do
    use_sourced
    config.config!('sidereal.runner.process') { :all }
    config.build!

    expect(config['sidereal.runner.process']).to eq(:all)
  end

  it "runs Sourced's dispatcher from Sidereal's runner, never from Sourced's own start" do
    use_sourced
    config.build!

    expect(config['sidereal.runner.process']).to eq(:leader)
    expect(config['sidereal.runner.targets']).to eq(['sourced.dispatcher'])
    expect(config.node('sourced.dispatcher')).to be_deferred
    expect(config.node('sidereal.dispatcher')).to be_deferred # Sidereal's own never starts
  end

  it "starts and stops Sourced's dispatcher as its process is promoted and demoted" do
    elector = Class.new do
      include Sidereal::Elector::Callbacks
      define_method(:initialize) { @leader = false }
      define_method(:leader?) { @leader }
      define_method(:start) { |_task| self }
      public :promote!, :demote!
    end.new
    use_sourced
    config.config!('sidereal.elector') { elector }
    config.config!('sourced.workers.count') { 1 }

    Sync do |task|
      config.start!(task)
      dispatcher = config['sourced.dispatcher']
      expect(dispatcher).not_to be_running

      elector.promote!
      expect(dispatcher).to be_running
      elector.demote!
      expect(dispatcher).not_to be_running
      elector.promote!
      expect(dispatcher).to be_running
    ensure
      config.teardown!
    end

    expect(config['sourced.dispatcher']).not_to be_running
  end

  it 'registers Sidereal commanders with Sourced as the config is prepared' do
    Sidereal.register(IntgCommander)
    use_sourced
    config.build!

    expect(Sourced.config).to be_declared(Sourced::Config.reactor_key(IntgCommander))
    expect(Sourced.router.reactors).to include(IntgCommander)
  end

  it "reports Sourced's terminal failures to Sidereal.exceptions" do
    reports = []
    Sidereal.exceptions.on_failure { |report| reports << report }
    use_sourced
    config.build!

    group = double('group', error_context: {}, fail: nil)
    message = IntgDoThing.new(payload: { n: 1 })
    Sourced.config['error_strategy'].call(RuntimeError.new('boom'), message, group)

    expect(reports.map { |r| [r.exception.message, r.message] }).to eq([['boom', message]])
  end

  it "keeps the error strategy the app implements" do
    use_sourced
    config.config!('sourced.error_strategy') { Sourced::ErrorStrategy.new.retry(times: 3) }
    config.build!

    expect(Sourced.config['error_strategy'].max_retries).to eq(3)
  end

  it "compiles Sourced's store codec on prepare, for every type defined by then, before anything connects" do
    use_sourced
    late = Sidereal::Message.define("boot_spec.late_#{SecureRandom.hex(4)}") do
      attribute :price, CodecMoney
    end
    msg = late.new(payload: { price: CodecMoney.new(cents: 250, currency: 'GBP') })

    config.prepare!

    expect(Sourced::Store::MessageCodec.default.encode(msg)['payload']).to eq('price' => '250 GBP')
    expect(config.node('db').status).to eq(:prepared)
  end

  it "installs Sourced's store tables on start" do
    use_sourced
    config.config!('sourced.workers.count') { 0 }
    msg = CodecPriced.new(payload: { price: CodecMoney.new(cents: 250, currency: 'GBP') })

    Sync do |task|
      config.start!(task)
      Sidereal.store.append(msg)
    ensure
      config.teardown!
    end

    expect(Sourced.store.read_correlation_batch(msg.id).map(&:payload).map(&:price)).to eq([msg.payload.price])
  end

  it "carries an app-registered encoder into Sourced's store" do
    # CodecMoneyEncoder is registered on the global Plumb::Codec::JSON (see
    # spec/support/codec_fixtures.rb), the way an app registers one. Sourced
    # knows the type because it compiles against that same global.
    use_sourced
    config.build!

    msg = CodecPriced.new(payload: { price: CodecMoney.new(cents: 250, currency: 'GBP') })
    expect(Sourced.store.message_codec.encode(msg)['payload']).to eq('price' => '250 GBP')
  end

  it 'keeps the two serializers apart, over the same format' do
    # Compiled explicitly: nothing compiles a codec on first use, and neither
    # transport nor store has started here.
    sourced_codec = Sourced::Store::MessageCodec.default.compile!
    sidereal_codec = Sourced::Message::JSONCodec.default.compile!
    expect(sourced_codec).not_to be(sidereal_codec)

    msg = CodecPriced.new(payload: { price: CodecMoney.new(cents: 250, currency: 'GBP') })
    # Same global encoders, so both encode the whole message the same way.
    expect(sourced_codec.encode(msg)).to eq(sidereal_codec.encode(msg))
    expect(sidereal_codec.encode(msg)).to include('type', 'id', 'created_at', 'payload' => { 'price' => '250 GBP' })
  end
end
