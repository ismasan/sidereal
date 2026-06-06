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
