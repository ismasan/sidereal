# frozen_string_literal: true

require 'spec_helper'
require 'sourced'
require 'sourced/store'
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
end
