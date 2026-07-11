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

  around do |example|
    original = Sidereal.config.pubsub
    Sidereal.config.pubsub = pubsub
    example.run
    Sidereal.config.pubsub = original
  end

  before do
    store.install!
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

  describe 'config.use(Sidereal::Integrations::Sourced)' do
    after { Sourced.reset! }

    it 'wires the dispatcher and a store proxy over the current Sourced store' do
      config = Sidereal::Configuration.new
      config.use(Sidereal::Integrations::Sourced, store: Sequel.sqlite)

      expect(config.dispatcher).to be(Sidereal::Integrations::Sourced::Dispatcher)

      # config.store delegates #append to whatever Sourced.store is at call time,
      # so a per-worker reconnect is picked up without re-pointing the config.
      expect(config.store).to be(Sidereal::Integrations::Sourced::StoreProxy)
      fake = double('sourced store')
      allow(Sourced).to receive(:store).and_return(fake)
      expect(fake).to receive(:append).with(:msg).and_return(:ok)
      expect(config.store.append(:msg)).to eq(:ok)
    end

    it 'wires Sourced retry/fail reporting to Sidereal.exceptions' do
      strategy = Sourced.config.error_strategy
      expect(strategy).to receive(:on_retry).with(Sidereal.exceptions)
      expect(strategy).to receive(:on_fail).with(Sidereal.exceptions)

      Sidereal::Configuration.new.use(Sidereal::Integrations::Sourced, store: Sequel.sqlite)
    end

    it 'is fork-safe: a callable store yields a fresh connection when Sourced re-establishes' do
      Sidereal::Configuration.new.use(
        Sidereal::Integrations::Sourced,
        store: -> { Sequel.sqlite }
      )
      store1 = Sourced.store

      # Sourced.setup! re-runs the store's configure block (what the dispatcher
      # factory does per worker) — a bare connection would be reused, a factory
      # opens a new one.
      Sourced.setup!

      expect(Sourced.store).not_to be(store1)
    end
  end

  describe 'Sidereal::Integrations::Sourced::Dispatcher.start' do
    it 're-establishes connections (Sourced.setup!) before starting the Sourced runtime' do
      task = double('task')
      allow(Sidereal.registry).to receive(:commanders).and_return([])
      expect(Sourced).to receive(:setup!).ordered
      expect(Sourced::Dispatcher).to receive(:start).with(task).ordered.and_return(:running)

      expect(Sidereal::Integrations::Sourced::Dispatcher.start(task)).to eq(:running)
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

  describe 'Sourced::Decider auto-publishes emitted events' do
    include Sourced::Testing::RSpec

    # Register resolvers on the global channels registry; reset around each
    # example so nothing leaks (and so a booted Host's lock never bites here).
    before { Sidereal.reset_channels! }
    after  { Sidereal.reset_channels! }

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
  end

  describe 'Sourced::Projector auto-generates + publishes a Projected signal' do
    include Sourced::Testing::RSpec

    before { Sidereal.reset_channels! }
    after  { Sidereal.reset_channels! }

    # Auto-defines MyProjector::Projected (single key) and publishes it end-to-end.
    it 'publishes the Projected signal on the resolved channel after a batch' do
      Sidereal.channels.channel_name(IntgThingProjector::Projected) { |m| "things.#{m.payload.thing_id}" }

      with_reactor(IntgThingProjector, thing_id: 't1')
        .when(IntgThingHappenedEvt, thing_id: 't1')
        .then!([])

      expect(pubsub.published.size).to eq(1)
      entry = pubsub.published.first
      expect(entry[:channel]).to eq('things.t1')
      expect(entry[:message]).to be_a(IntgThingProjector::Projected)
      expect(entry[:message].payload.thing_id).to eq('t1')
    end

    it 'carries every key for a multi-key partition (partition_values, not read-model state)' do
      # The projector's evolve only writes student_id into state — the published
      # signal still carries BOTH keys, proving the payload comes from
      # partition_values rather than read-model state.
      Sidereal.channels.channel_name(IntgEnrollmentProjector::Projected) do |m|
        "enroll.#{m.payload.student_id}.#{m.payload.course_id}"
      end

      with_reactor(IntgEnrollmentProjector, student_id: 's1', course_id: 'c1')
        .when(IntgEnrolledEvt, student_id: 's1', course_id: 'c1')
        .then!([])

      expect(pubsub.published.size).to eq(1)
      entry = pubsub.published.first
      expect(entry[:channel]).to eq('enroll.s1.c1')
      expect(entry[:message].payload.to_h).to include(student_id: 's1', course_id: 'c1')
    end
  end
end
