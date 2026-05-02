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
    it 'parses the cron and adds an immutable Schedule with monotonic id and the supplied name' do
      scheduler.schedule('Every minute', '* * * * *') {}
      scheduler.schedule('Daily at 00:05', '5 0 * * *') {}
      scheduler.schedule('Every 10 min', '*/10 * * * *') {}

      expect(scheduler.schedules.map(&:id)).to eq([0, 1, 2])
      expect(scheduler.schedules.map(&:name)).to eq(['Every minute', 'Daily at 00:05', 'Every 10 min'])

      first = scheduler.schedules.first
      expect(first).to be_frozen
      expect(first.cron_expr).to eq('* * * * *')
      expect(first.name).to eq('Every minute')
    end

    it 'allows multiple schedules sharing the same cron expression' do
      scheduler.schedule('A', '5 0 * * *') {}
      scheduler.schedule('B', '5 0 * * *') {}

      expect(scheduler.schedules.size).to eq(2)
      expect(scheduler.schedules.map(&:id)).to eq([0, 1])
      expect(scheduler.schedules.map(&:name)).to eq(['A', 'B'])
      expect(scheduler.schedules.map(&:cron_expr)).to eq(['5 0 * * *', '5 0 * * *'])
    end

    it 'raises ArgumentError on a malformed cron expression' do
      expect { scheduler.schedule('Bad', 'not a cron') {} }.to raise_error(ArgumentError, /invalid cron/)
    end

    it 'auto-names the schedule when only a cron_expr is supplied' do
      scheduler.schedule('5 0 * * *') {}
      scheduler.schedule('* * * * *') {}

      expect(scheduler.schedules.map(&:name)).to eq(['0 (5 0 * * *)', '1 (* * * * *)'])
    end

    it 'raises on bad arity' do
      expect { scheduler.schedule {} }.to raise_error(ArgumentError, /schedule takes/)
      expect { scheduler.schedule('a', 'b', 'c') {} }.to raise_error(ArgumentError, /schedule takes/)
    end
  end

  describe '#schedule with from:/to:' do
    let(:from_t) { Time.local(2026, 6, 1, 0, 0, 0) }
    let(:to_t)   { Time.local(2026, 6, 1, 23, 59, 59) }

    it 'accepts Time objects unchanged' do
      scheduler.schedule('Daily', '5 0 * * *', from: from_t, to: to_t) {}
      sch = scheduler.schedules.first
      expect(sch.from).to eq(from_t)
      expect(sch.to).to eq(to_t)
    end

    it 'parses ISO8601 strings to Time' do
      scheduler.schedule('Daily', '5 0 * * *',
                         from: '2026-02-03T10:00:00Z',
                         to: '2026-10-01T00:00:00Z') {}
      sch = scheduler.schedules.first
      expect(sch.from).to be_a(Time)
      expect(sch.from).to eq(Time.utc(2026, 2, 3, 10, 0, 0))
      expect(sch.to).to be_a(Time)
      expect(sch.to).to eq(Time.utc(2026, 10, 1, 0, 0, 0))
    end

    it 'normalises DateTime via .to_time' do
      require 'date'
      dt = DateTime.new(2026, 6, 1, 12, 0, 0)
      scheduler.schedule('Daily', '5 0 * * *', from: dt, to: dt + 30) {}
      expect(scheduler.schedules.first.from).to be_a(Time)
    end

    it 'raises ArgumentError on a non-Time, non-String, non-DateTime input' do
      expect {
        scheduler.schedule('Bad', '5 0 * * *', from: 12345) {}
      }.to raise_error(ArgumentError, /expected Time, DateTime, or ISO8601 String/)
    end

    it 'raises when both bounds are given and the cron never fires inside the window' do
      # Daily at 00:05 with a 30-minute window starting at 12:00 — never fires.
      expect {
        scheduler.schedule('Daily', '5 0 * * *',
                           from: Time.local(2026, 6, 1, 12, 0, 0),
                           to:   Time.local(2026, 6, 1, 12, 30, 0)) {}
      }.to raise_error(ArgumentError, /never fires inside the window/)
    end

    it 'accepts only from: without validation' do
      expect {
        scheduler.schedule('Hourly from now', '0 * * * *', from: Time.now) {}
      }.not_to raise_error
    end

    it 'accepts only to: without validation' do
      expect {
        scheduler.schedule('Hourly until far future', '0 * * * *', to: Time.now + 86400) {}
      }.not_to raise_error
    end

    it 'leaves from/to nil when not provided (existing schedules)' do
      scheduler.schedule('Plain', '5 0 * * *') {}
      sch = scheduler.schedules.first
      expect(sch.from).to be_nil
      expect(sch.to).to be_nil
    end
  end

  describe '#find' do
    it 'returns the registered schedule by integer id' do
      scheduler.schedule('First', '* * * * *') {}
      scheduler.schedule('Second', '5 0 * * *') {}

      expect(scheduler.find(0).name).to eq('First')
      expect(scheduler.find(1).name).to eq('Second')
    end

    it 'returns nil for an unknown id' do
      expect(scheduler.find(99)).to be_nil
    end
  end

  describe '#tick' do
    it 'fires nothing on the first tick (window is empty)' do
      scheduler.schedule('Every minute', '* * * * *') {}
      scheduler.tick
      expect(store.appended).to be_empty
    end

    it 'dispatches a TriggerSchedule with schedule_id, schedule_name and producer_label metadata' do
      scheduler.schedule('Every minute', '* * * * *') {}
      scheduler.tick           # baseline
      advance(60)
      scheduler.tick

      expect(store.appended.size).to eq(1)
      msg = store.appended.first
      expect(msg).to be_a(Sidereal::System::TriggerSchedule)
      expect(msg.payload.schedule_id).to eq(0)
      expect(msg.payload.schedule_name).to eq('Every minute')
      expect(msg.metadata[:producer]).to eq("Schedule #0 'Every minute' (* * * * *)")
    end

    it 'dispatches one TriggerSchedule per due schedule, even when crons overlap' do
      scheduler.schedule('A', '* * * * *') {}
      scheduler.schedule('B', '* * * * *') {}
      scheduler.tick
      advance(60)
      scheduler.tick

      expect(store.appended.size).to eq(2)
      expect(store.appended.map { |m| m.payload.schedule_id }).to contain_exactly(0, 1)
      expect(store.appended.map { |m| m.payload.schedule_name }).to contain_exactly('A', 'B')
    end

    it 'fires each schedule at most once per tick (no catch-up — matches crond)' do
      scheduler.schedule('Every minute', '* * * * *') {}
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
      sched.schedule('A', '* * * * *') {}
      sched.schedule('B', '* * * * *') {}

      sched.tick
      advance(60)
      sched.tick

      # Second schedule still gets its TriggerSchedule even though the first raised.
      expect(flaky.appended.size).to eq(1)
      expect(flaky.appended.first.payload.schedule_id).to eq(1)
    end

    it 'does not mutate registered Schedules across ticks' do
      scheduler.schedule('Every minute', '* * * * *') {}
      original = scheduler.schedules.first
      scheduler.tick
      advance(120)
      scheduler.tick
      expect(scheduler.schedules.first).to eq(original)
    end
  end

  describe '#tick with windowed schedules' do
    it 'skips a schedule whose from: is still in the future' do
      scheduler.schedule('Every minute', '* * * * *', from: t0 + 60) {}
      scheduler.tick           # baseline at t0
      advance(30)              # now = t0 + 30, before from
      scheduler.tick

      expect(store.appended).to be_empty
    end

    it 'fires once from: has passed and a cron boundary fell inside the active window' do
      scheduler.schedule('Every minute', '* * * * *', from: t0 + 60) {}
      scheduler.tick           # baseline at t0
      advance(90)              # now = t0 + 90 — past from + crossed t0+60 minute boundary
      scheduler.tick

      expect(store.appended.size).to eq(1)
    end

    it 'fires before to:, skips after to:' do
      scheduler.schedule('Every minute', '* * * * *', to: t0 + 90) {}
      scheduler.tick           # baseline at t0
      advance(60)              # now = t0 + 60 — before to:, boundary crossed
      scheduler.tick
      expect(store.appended.size).to eq(1)

      advance(120)             # now = t0 + 180 — past to:
      scheduler.tick
      expect(store.appended.size).to eq(1)   # no new fire
    end

    it 'with both bounds, fires inside the window and skips outside' do
      scheduler.schedule('Every minute', '* * * * *',
                         from: t0 + 60, to: t0 + 180) {}

      scheduler.tick           # baseline at t0
      advance(30)              # before from
      scheduler.tick
      expect(store.appended.size).to eq(0)

      advance(60)              # now = t0 + 90 — inside window, boundary at t0+60 crossed
      scheduler.tick
      expect(store.appended.size).to eq(1)

      advance(180)             # now = t0 + 270 — past to:
      scheduler.tick
      expect(store.appended.size).to eq(1)   # no further fire
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
      scheduler.schedule('Tick', '* * * * *') { record(:fired) }
      scheduler.find(0).run_in(recorder, fake_cmd)

      expect(recorder.seen).to eq([:fired])
    end

    it 'yields the triggering cmd to the block' do
      scheduler.schedule('Tick', '* * * * *') { |cmd| record(cmd) }
      scheduler.find(0).run_in(recorder, fake_cmd)

      expect(recorder.seen).to eq([fake_cmd])
    end

    it 'tolerates blocks that do not declare a cmd parameter (proc semantics)' do
      scheduler.schedule('Tick', '* * * * *') { record(:no_arg_block) }
      expect { scheduler.find(0).run_in(recorder, fake_cmd) }.not_to raise_error
      expect(recorder.seen).to eq([:no_arg_block])
    end
  end

  describe 'fiber lifecycle' do
    it 'fires at least once when started under a real Async task with a fast tick interval' do
      sched = described_class.new(tick_interval: 0.05, store: store)
      sched.schedule('Every second', '* * * * * *') {}

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
      sched.schedule('Every second', '* * * * * *') {}

      Sync do |task|
        sched.start(task)
        sleep 1.2
        task.stop
      end

      expect(store.appended).to be_empty
    end

    it 'starts ticking on promotion and stops on demotion' do
      sched = described_class.new(tick_interval: 0.02, store: store, elector: elector)
      sched.schedule('Every second', '* * * * * *') {}

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
