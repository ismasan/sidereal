# frozen_string_literal: true

require 'spec_helper'

# -- Fake store: records appends without async machinery --

class RecordingStore
  attr_reader :appended

  def initialize
    @appended = []
  end

  def append(msg)
    @appended << msg
    true
  end
end

RSpec.describe Sidereal::Scheduler do
  let(:store) { RecordingStore.new }

  # Anchored on a Monday at 12:00:00 so cron math is predictable across
  # day-of-week and minute boundaries.
  let(:t0) { Time.local(2026, 5, 4, 12, 0, 0) }
  let(:clock_holder) { [t0] }
  let(:clock) { -> { clock_holder.first } }

  def advance(seconds)
    clock_holder[0] = clock_holder.first + seconds
  end

  subject(:scheduler) { described_class.new(clock: clock, store: store) }

  describe '#schedule' do
    it 'parses the cron and adds an immutable Schedule with a monotonic integer id' do
      scheduler.schedule('* * * * *') {}
      scheduler.schedule('5 0 * * *') {}
      scheduler.schedule('*/10 * * * *') {}

      ids = scheduler.schedules.map(&:id)
      expect(ids).to eq([0, 1, 2])

      first = scheduler.schedules.first
      expect(first).to be_frozen
      expect(first.cron_expr).to eq('* * * * *')
    end

    it 'allows multiple schedules sharing the same cron expression' do
      scheduler.schedule('5 0 * * *') {}
      scheduler.schedule('5 0 * * *') {}

      expect(scheduler.schedules.size).to eq(2)
      expect(scheduler.schedules.map(&:id)).to eq([0, 1])
      expect(scheduler.schedules.map(&:cron_expr)).to eq(['5 0 * * *', '5 0 * * *'])
    end

    it 'raises ArgumentError on a malformed cron expression' do
      expect { scheduler.schedule('not a cron') {} }.to raise_error(ArgumentError, /invalid cron/)
    end
  end

  describe '#find' do
    it 'returns the registered schedule by integer id' do
      scheduler.schedule('* * * * *') {}
      scheduler.schedule('5 0 * * *') {}

      expect(scheduler.find(0).cron_expr).to eq('* * * * *')
      expect(scheduler.find(1).cron_expr).to eq('5 0 * * *')
    end

    it 'returns nil for an unknown id' do
      expect(scheduler.find(99)).to be_nil
    end
  end

  describe '#tick' do
    it 'fires nothing on the first tick (window is empty)' do
      scheduler.schedule('* * * * *') {}
      scheduler.tick
      expect(store.appended).to be_empty
    end

    it 'dispatches a TriggerSchedule when a schedule fires inside (last_tick_at, now]' do
      scheduler.schedule('* * * * *') {}
      scheduler.tick           # baseline
      advance(60)
      scheduler.tick

      expect(store.appended.size).to eq(1)
      msg = store.appended.first
      expect(msg).to be_a(Sidereal::System::TriggerSchedule)
      expect(msg.payload.schedule_id).to eq(0)
      expect(msg.metadata[:producer]).to eq('Schedule #0 (* * * * *)')
    end

    it 'dispatches one TriggerSchedule per due schedule, even when crons overlap' do
      scheduler.schedule('* * * * *') {}
      scheduler.schedule('* * * * *') {}
      scheduler.tick
      advance(60)
      scheduler.tick

      expect(store.appended.size).to eq(2)
      expect(store.appended.map { |m| m.payload.schedule_id }).to contain_exactly(0, 1)
    end

    it 'fires each schedule at most once per tick (no catch-up — matches crond)' do
      scheduler.schedule('* * * * *') {}
      scheduler.tick
      advance(5 * 60 + 30)
      scheduler.tick

      expect(store.appended.size).to eq(1)
    end

    it 'continues running when a store append raises for one schedule' do
      flaky = Class.new(RecordingStore) do
        def append(msg)
          raise 'first one fails' if @appended.empty? && msg.payload.schedule_id.zero?
          super
        end
      end.new
      sched = described_class.new(clock: clock, store: flaky)
      sched.schedule('* * * * *') {}
      sched.schedule('* * * * *') {}

      sched.tick
      advance(60)
      sched.tick

      # Second schedule still gets its TriggerSchedule even though the first raised.
      expect(flaky.appended.size).to eq(1)
      expect(flaky.appended.first.payload.schedule_id).to eq(1)
    end

    it 'does not mutate registered Schedules across ticks' do
      scheduler.schedule('* * * * *') {}
      original = scheduler.schedules.first
      scheduler.tick
      advance(120)
      scheduler.tick
      expect(scheduler.schedules.first).to eq(original)
    end
  end

  describe 'Schedule#run_in' do
    let(:recorder) do
      Class.new do
        attr_reader :seen
        def record(value); (@seen ||= []) << value; end
      end.new
    end

    let(:fake_cmd) { Object.new }

    it 'instance_execs the block on the given context' do
      scheduler.schedule('* * * * *') { record(:fired) }
      scheduler.find(0).run_in(recorder, fake_cmd)

      expect(recorder.seen).to eq([:fired])
    end

    it 'yields the triggering cmd to the block' do
      scheduler.schedule('* * * * *') { |cmd| record(cmd) }
      scheduler.find(0).run_in(recorder, fake_cmd)

      expect(recorder.seen).to eq([fake_cmd])
    end

    it 'tolerates blocks that do not declare a cmd parameter (proc semantics)' do
      scheduler.schedule('* * * * *') { record(:no_arg_block) }
      expect { scheduler.find(0).run_in(recorder, fake_cmd) }.not_to raise_error
      expect(recorder.seen).to eq([:no_arg_block])
    end
  end

  describe 'fiber lifecycle' do
    it 'fires at least once when started under a real Async task with a fast tick interval' do
      sched = described_class.new(tick_interval: 0.05, store: store)
      sched.schedule('* * * * * *') {}

      Sync do |task|
        sched.start(task)
        # The very-second cron + 50ms tick should fire within ~1.1s.
        sleep 1.2
        task.stop
      end

      expect(store.appended.size).to be >= 1
      expect(store.appended.first).to be_a(Sidereal::System::TriggerSchedule)
    end
  end

  describe 'elector integration' do
    let(:test_elector_class) do
      Class.new do
        include Sidereal::Elector::Callbacks
        def initialize = @leader = false
        def leader? = @leader
        def start(_task) = self
        public :promote!, :demote!
      end
    end

    let(:elector) { test_elector_class.new }

    it 'does not tick while the elector reports follower' do
      sched = described_class.new(tick_interval: 0.02, store: store, elector: elector)
      sched.schedule('* * * * * *') {}

      Sync do |task|
        sched.start(task)
        sleep 1.2
        task.stop
      end

      expect(store.appended).to be_empty
    end

    it 'starts ticking on promotion and stops on demotion' do
      sched = described_class.new(tick_interval: 0.02, store: store, elector: elector)
      sched.schedule('* * * * * *') {}

      Sync do |task|
        sched.start(task)
        sleep 0.1
        expect(store.appended).to be_empty   # not leader yet

        elector.promote!
        sleep 1.2
        expect(store.appended.size).to be >= 1

        elector.demote!
        before = store.appended.size
        sleep 1.2
        expect(store.appended.size).to eq(before)

        task.stop
      end
    end
  end
end
