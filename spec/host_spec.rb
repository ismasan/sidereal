# frozen_string_literal: true

require 'spec_helper'

# Unit coverage for the boot-orchestration layer. {Sidereal::Host} is the
# thing {Sidereal::Falcon::Environment::Service} drives at startup: it locks
# the channels/exceptions registries, then starts elector → pubsub →
# dispatcher → scheduler, and on shutdown stops the *running* dispatcher
# instance it captured from +dispatcher.start+.
#
# Collaborators are injected as fakes that record their lifecycle calls into
# a shared +events+ log, so ordering and the start/stop wiring can be asserted
# directly. The channels/exceptions registries are the real objects — we
# assert their public +#locked?+ predicate rather than spying, which also
# catches "locked the wrong registry" bugs.
RSpec.describe Sidereal::Host do
  # Opaque sentinel — Host only threads it through to each subsystem's #start.
  let(:task) { Object.new }

  # Ordered log of lifecycle calls across all fake collaborators.
  let(:events) { [] }

  # Real registries: start unlocked, expose #locked?.
  let(:channels) { Sidereal::Channels.with_system_defaults }
  let(:exceptions) { Sidereal::Exceptions.new }

  # Fake startable subsystem (mirrors elector/pubsub/scheduler): records
  # #start(task) and returns self, like the real singletons do.
  def fake_startable(label)
    log = events
    Class.new do
      define_method(:start) do |t|
        log << [label, :start, t]
        self
      end
    end.new
  end

  let(:elector)   { fake_startable(:elector) }
  let(:pubsub)    { fake_startable(:pubsub) }
  let(:scheduler) { fake_startable(:scheduler) }

  # The running dispatcher instance — the object #start hands back and the
  # only thing Host#stop should ever stop.
  let(:running_dispatcher) do
    log = events
    Class.new do
      define_method(:stop) { log << [:running_dispatcher, :stop] }
    end.new
  end

  # The `dispatcher` field is a *factory* (the real one is the Dispatcher
  # class) whose #start returns a distinct running instance. It also snapshots
  # the registries' lock-state at the moment it is started, so we can assert
  # both registries are already locked before the dispatcher begins consuming.
  let(:dispatcher) do
    log = events
    running = running_dispatcher
    chans = channels
    excs = exceptions
    Class.new do
      define_method(:start) do |t|
        log << [:dispatcher, :start, t,
                { channels_locked: chans.locked?, exceptions_locked: excs.locked? }]
        running
      end
    end.new
  end

  subject(:host) do
    Sidereal::Host.new(
      channels:, exceptions:, elector:, pubsub:, dispatcher:, scheduler:
    )
  end

  describe '#start' do
    it 'locks both the channels and exceptions registries' do
      expect { host.start(task) }
        .to change(channels, :locked?).from(false).to(true)
        .and change(exceptions, :locked?).from(false).to(true)
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

  describe 'boot hooks' do
    subject(:host) do
      Sidereal::Host.new(
        channels:, exceptions:, elector:, pubsub:, dispatcher:, scheduler:,
        boot_hooks: [
          -> { events << [:hook, :one, { channels_locked: channels.locked? }] },
          -> { events << [:hook, :two] }
        ]
      )
    end

    it 'runs them in order, before the registries lock and before any subsystem starts' do
      host.start(task)

      expect(events.first(2)).to eq([[:hook, :one, { channels_locked: false }], [:hook, :two]])
      expect(events.drop(2).map(&:first)).to eq(%i[elector pubsub dispatcher scheduler])
    end

    it 'fails the boot when a hook raises: nothing starts' do
      failing = Sidereal::Host.new(
        channels:, exceptions:, elector:, pubsub:, dispatcher:, scheduler:,
        boot_hooks: [-> { raise 'no database' }]
      )

      expect { failing.start(task) }.to raise_error(RuntimeError, 'no database')
      expect(events).to be_empty
      expect(channels).not_to be_locked
    end
  end

  describe 'dispatcher_process: :leader' do
    # Elector that starts as follower and lets the spec drive transitions
    # through the same promote!/demote! the real electors call.
    let(:elector) do
      log = events
      Class.new do
        include Sidereal::Elector::Callbacks
        define_method(:initialize) { @leader = false }
        define_method(:leader?) { @leader }
        define_method(:start) do |t|
          log << [:elector, :start, t]
          self
        end
        public :promote!, :demote!
      end.new
    end

    subject(:host) do
      Sidereal::Host.new(
        channels:, exceptions:, elector:, pubsub:, dispatcher:, scheduler:,
        dispatcher_process: :leader
      )
    end

    def dispatcher_starts = events.count { |e| e[0] == :dispatcher && e[1] == :start }
    def dispatcher_stops = events.count { |e| e == [:running_dispatcher, :stop] }

    it 'does not start the dispatcher on a follower, and still starts the rest in order' do
      host.start(task)

      starts = events.select { |e| e[1] == :start }
      expect(starts.map(&:first)).to eq(%i[elector pubsub scheduler])
      expect(dispatcher_starts).to eq(0)
    end

    it 'starts the dispatcher once on promotion, with the registries already locked' do
      host.start(task)
      elector.promote!
      elector.promote! # same state: the elector does not re-fire

      expect(dispatcher_starts).to eq(1)
      dispatch_start = events.find { |e| e[0] == :dispatcher && e[1] == :start }
      expect(dispatch_start[2]).to be(task)
      expect(dispatch_start.last).to eq(channels_locked: true, exceptions_locked: true)
    end

    it 'stops the running dispatcher on demotion and starts a fresh one on re-promotion' do
      host.start(task)
      elector.promote!
      elector.demote!
      expect(dispatcher_stops).to eq(1)

      elector.promote!
      expect(dispatcher_starts).to eq(2)
    end

    it 'stops the running dispatcher from #stop, once' do
      host.start(task)
      elector.promote!

      host.stop
      host.stop
      expect(dispatcher_stops).to eq(1)
    end

    it 'stops nothing from #stop while a follower' do
      host.start(task)
      host.stop
      expect(dispatcher_stops).to eq(0)
    end

    it 'behaves like :all under an elector that is leader from construction' do
      always = Class.new do
        include Sidereal::Elector::Callbacks
        define_method(:initialize) { @leader = true }
        define_method(:leader?) { @leader }
        define_method(:start) { |_t| self }
      end.new

      leader_host = Sidereal::Host.new(
        channels:, exceptions:, elector: always, pubsub:, dispatcher:, scheduler:,
        dispatcher_process: :leader
      )
      leader_host.start(task)

      starts = events.select { |e| e[1] == :start }
      expect(starts.map(&:first)).to eq(%i[pubsub dispatcher scheduler])
    end

    it 'rejects an unknown mode at construction' do
      expect do
        Sidereal::Host.new(
          channels:, exceptions:, elector:, pubsub:, dispatcher:, scheduler:,
          dispatcher_process: :some
        )
      end.to raise_error(Plumb::ParseError)
    end
  end

  describe '#stop' do
    it 'stops the running dispatcher instance returned by #start (not the factory or scheduler)' do
      host.start(task)

      # The scheduler/dispatcher-factory fakes don't define #stop, so a
      # mis-wired capture (stopping the scheduler, or the class) would raise.
      expect { host.stop }.not_to raise_error
      expect(events).to include([:running_dispatcher, :stop])
    end

    it 'is a safe no-op when #start was never called' do
      expect { host.stop }.not_to raise_error
      expect(events).to be_empty
    end
  end
end
