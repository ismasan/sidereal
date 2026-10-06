# frozen_string_literal: true

require 'spec_helper'

# Unit coverage for the boot-orchestration layer. {Sidereal::Host} is the
# thing {Sidereal::Falcon::Environment::Service} drives at startup: it starts
# Sidereal.config, whose components lock the channels/exceptions registries,
# then start elector → pubsub → dispatcher → scheduler, and on shutdown it
# stops the dispatcher before tearing the rest down.
#
# Sidereal's components are implemented with fakes that record their lifecycle
# calls into a shared +events+ log, so ordering can be asserted directly. The
# channels/exceptions registries are the real objects — we assert their public
# +#locked?+ predicate rather than spying.
RSpec.describe Sidereal::Host do
  # Opaque sentinel — Host only threads it through to each component's start.
  let(:task) { Object.new }

  # Ordered log of lifecycle calls across all fakes.
  let(:events) { [] }

  let(:config) { Sidereal.config }

  # Fake startable component (mirrors elector/pubsub/scheduler): records
  # #start(task) and returns self, like the real ones do.
  def fake_startable(label, **methods)
    log = events
    Class.new do
      define_method(:start) do |t|
        log << [label, :start, t]
        self
      end
      methods.each { |name, value| define_method(name) { |*| value } }
    end.new
  end

  # A dispatcher that snapshots the registries' lock-state when it starts, so
  # we can assert both registries are locked before it begins consuming.
  let(:dispatcher) do
    log = events
    Class.new do
      define_method(:start) do |t|
        log << [:dispatcher, :start, t,
                { channels_locked: Sidereal.channels.locked?, exceptions_locked: Sidereal.exceptions.locked? }]
        self
      end
      define_method(:stop) { log << %i[dispatcher stop] }
    end.new
  end

  before do
    elector = Sidereal::Elector::AlwaysLeader.new
    log = events
    config.component!('sidereal.elector') do
      build { elector }
      start { |_, t| log << [:elector, :start, t] }
    end
    pubsub = fake_startable(:pubsub, subscribe: nil, publish: nil)
    config.component!('sidereal.pubsub', ['sidereal.elector']) do
      build { |_| pubsub }
      start { |p, t| p.start(t) }
    end
    dispatcher = self.dispatcher
    config.component!('sidereal.dispatcher') do
      build { dispatcher }
      start { |d, t| d.start(t) }
      stop(&:stop)
    end
    scheduler = fake_startable(:scheduler)
    config.component!('sidereal.scheduler', ['sidereal.runner']) do
      build { |_| scheduler }
      start { |s, t| s.start(t) }
    end
  end

  subject(:host) { described_class.new(config:) }

  describe '#start' do
    it 'locks both the channels and exceptions registries' do
      expect { host.start(task) }
        .to change(Sidereal.channels, :locked?).from(false).to(true)
        .and change(Sidereal.exceptions, :locked?).from(false).to(true)
    end

    it 'starts elector, pubsub, dispatcher and scheduler in order, threading the task to each' do
      host.start(task)

      starts = events.select { |e| e[1] == :start }
      expect(starts.map(&:first)).to eq(%i[elector pubsub dispatcher scheduler])
      expect(starts.map { |e| e[2] }).to all(be(task))
    end

    it 'locks both registries before the dispatcher starts consuming' do
      host.start(task)

      dispatch_start = events.find { |e| e[0] == :dispatcher && e[1] == :start }
      expect(dispatch_start.last).to eq(channels_locked: true, exceptions_locked: true)
    end

    it 'returns self' do
      expect(host.start(task)).to be(host)
    end
  end

  describe "the app's components" do
    before do
      log = events
      config.declare('db')
      config.component!('db') do
        build { log << %i[db build] }
        teardown { |_| log << %i[db teardown] }
      end
    end

    it 'are built before anything starts' do
      host.start(task)

      expect(events.first).to eq(%i[db build])
      expect(events.drop(1).map(&:first)).to eq(%i[elector pubsub dispatcher scheduler])
    end

    it 'are built while the registries are still open, so they can register subscribers' do
      config.declare('apm')
      config.config!('apm') { Sidereal.exceptions.on_failure { |_report| } }

      expect { host.start(task) }.not_to raise_error
      expect(Sidereal.exceptions).to be_locked
    end

    it 'fail the boot when one raises: nothing starts' do
      config.declare('flaky')
      config.config!('flaky') { raise 'no database' }

      expect { host.start(task) }.to raise_error(RuntimeError, 'no database')
      expect(events.map(&:first)).not_to include(:elector, :dispatcher)
      expect(Sidereal.channels).not_to be_locked
    end

    it 'fail the boot when they depend on undeclared components: nothing is built' do
      config.declare('store')
      config.config!('store', ['missing']) { |_| :store }

      expect { host.start(task) }.to raise_error(Sourced::Component::MissingDependencyError)
      expect(events).to be_empty
    end

    it 'are torn down from #stop, after the dispatcher stops' do
      host.start(task)
      host.stop

      expect(events.index(%i[dispatcher stop])).to be < events.index(%i[db teardown])
    end
  end

  describe '#stop' do
    it 'stops the dispatcher once' do
      host.start(task)
      host.stop
      host.stop

      expect(events.count(%i[dispatcher stop])).to eq(1)
    end

    it 'is a safe no-op when #start was never called' do
      expect { host.stop }.not_to raise_error
      expect(events).to be_empty
    end
  end
end
