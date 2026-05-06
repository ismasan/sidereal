# frozen_string_literal: true

require 'spec_helper'

# Test message classes used by the step-based Scheduler tests below.
TestSchedFirst  = Sidereal::Message.define('test.sched_first')
TestSchedSecond = Sidereal::Message.define('test.sched_second')
TestSchedThird  = Sidereal::Message.define('test.sched_third')
TestSchedFourth = Sidereal::Message.define('test.sched_fourth')
TestSchedFifth  = Sidereal::Message.define('test.sched_fifth')

TestSchedRun = Sidereal::Message.define('test.sched_run') do
  attribute :n, Sidereal::Types::Integer
end

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
  let(:t0)    { Time.local(2026, 5, 4, 12, 0, 0) }

  subject(:scheduler) { described_class.new(store: store, baseline: t0) }

  describe 'Schedule construction & validation' do
    it 'raises if name is nil or empty' do
      expect { Sidereal::Scheduler::Schedule.new(nil) }.to raise_error(ArgumentError, /name is required/)
      expect { Sidereal::Scheduler::Schedule.new('')  }.to raise_error(ArgumentError, /name is required/)
    end

    it 'raises if a schedule has no steps' do
      expect {
        scheduler.schedule('Empty') { |_sc| }
      }.to raise_error(ArgumentError, /must declare at least one at/)
    end

    it 'raises on an unparseable expression' do
      expect {
        scheduler.schedule 'Bad' do |sc|
          sc.at 'not a real expression', TestSchedFirst
        end
      }.to raise_error(ArgumentError, /invalid expression/)
    end

    it 'raises if a block is passed to Schedule#at directly (block form is Scheduling-only)' do
      expect {
        scheduler.schedule 'NoBlocks' do |sc|
          sc.at('every minute') {}
        end
      }.to raise_error(ArgumentError, /block form is supported only via Sidereal::Scheduling/)
    end

    it 'raises when a specific datetime travels backwards relative to a previous concrete step' do
      expect {
        scheduler.schedule 'Backwards' do |sc|
          sc.at '2026-06-01T12:00:00', TestSchedFirst
          sc.at '2026-05-01T12:00:00', TestSchedSecond
        end
      }.to raise_error(ArgumentError, /must be after the previous concrete time/)
    end

    it 'raises when two recurring steps follow each other without a concrete bound between them' do
      expect {
        scheduler.schedule 'BackToBack' do |sc|
          sc.at 'every minute', TestSchedFirst
          sc.at 'every hour',   TestSchedSecond
        end
      }.to raise_error(ArgumentError, /must separate two recurring/)
    end

    it 'allows a past first specific datetime (it just never fires)' do
      expect {
        scheduler.schedule 'Past' do |sc|
          sc.at '2025-01-01T00:00:00', TestSchedFirst
          sc.at '5m', TestSchedSecond   # resolves against the past first step
        end
      }.not_to raise_error
    end

    it 'rejects non-String, non-Schedule first argument' do
      expect { scheduler.schedule(42) }.to raise_error(ArgumentError, /expected Schedule or String name/)
    end

    it 'accepts a Time instance as a specific step expression' do
      target = t0 + 10
      scheduler.schedule 'TimeInput' do |sc|
        sc.at target, TestSchedFirst
      end

      step = scheduler.schedules.first.steps.first
      expect(step).to be_a(Sidereal::Scheduler::Schedule::Step::Specific)
      expect(step.at).to eq(target)
    end

    it 'accepts a DateTime instance (any to_time responder) as a specific step expression' do
      require 'date'
      target = DateTime.new(2026, 6, 1, 12, 0, 0)
      scheduler.schedule 'DateTimeInput' do |sc|
        sc.at target, TestSchedFirst
      end

      step = scheduler.schedules.first.steps.first
      expect(step).to be_a(Sidereal::Scheduler::Schedule::Step::Specific)
      expect(step.at).to eq(target.to_time)
    end

    it 'accepts a Time as a bound-only marker (no class)' do
      target = t0 + 10
      scheduler.schedule 'TimeMarker' do |sc|
        sc.at target
        sc.at 'every minute', TestSchedRun, n: 1
      end

      sch = scheduler.schedules.first
      expect(sch.steps[0].klass).to be_nil
      expect(sch.steps[0].at).to eq(target)
      expect(sch.steps[1].from).to eq(target)
    end

    it 'allows a bound-only marker step (specific datetime, no class) — anchors but never fires' do
      scheduler.schedule 'Anchor + recurring' do |sc|
        sc.at '2026-05-04T10:00:00'        # marker — no class
        sc.at '*/5 * * * *', TestSchedRun, n: 1
      end

      sch = scheduler.schedules.first
      expect(sch.steps[0]).to be_a(Sidereal::Scheduler::Schedule::Step::Specific)
      expect(sch.steps[0].klass).to be_nil
      expect(sch.steps[1]).to be_a(Sidereal::Scheduler::Schedule::Step::Recurring)
      expect(sch.steps[1].from).to eq(Time.parse('2026-05-04T10:00:00'))
    end

    it 'allows a bound-only duration marker — anchors a relative point without dispatching' do
      scheduler.schedule 'Delayed start' do |sc|
        sc.at '5m'                          # marker — boot + 5m, no class
        sc.at 'every minute', TestSchedRun, n: 1
      end

      sch = scheduler.schedules.first
      expect(sch.steps[0].klass).to be_nil
      expect(sch.steps[0].at).to eq(t0 + 5 * 60)
      expect(sch.steps[1].from).to eq(t0 + 5 * 60)
    end

    it 'raises when a recurring step has no class (bound-only recurring is meaningless)' do
      expect {
        scheduler.schedule 'BadMarker' do |sc|
          sc.at 'every minute'   # recurring with no class — would fire nothing forever
        end
      }.to raise_error(ArgumentError, /recurring step.*requires a command class/)
    end

    it 'accepts a pre-built Schedule passed positionally' do
      built = Sidereal::Scheduler::Schedule.new('Pre')
      built.at '* * * * *', TestSchedRun, n: 1

      scheduler.schedule(built)
      expect(scheduler.schedules.size).to eq(1)
      expect(scheduler.schedules.first).to equal(built)
    end
  end

  describe 'resolution walk (Campaign 1)' do
    it 'resolves the user example end-to-end with the right step types and times' do
      scheduler.schedule 'Campaign 1' do |sc|
        sc.at '2026-05-03T10:00:00', TestSchedFirst   # T0
        sc.at '3m',                  TestSchedSecond  # T0 + 3m
        sc.at '*/5 * * * *',           TestSchedThird   # recurring from T0+3m
        sc.at '10h',                 TestSchedFourth  # T0 + 3m + 10h
        sc.at '2026-05-06T09:00:00', TestSchedFifth   # closes nothing; pure specific
      end

      sch = scheduler.schedules.first
      steps = sch.steps
      expect(steps.size).to eq(5)

      t0 = Time.parse('2026-05-03T10:00:00')
      t1 = t0 + 3 * 60                  # T0 + 3m
      t2 = t1 + 10 * 3600               # T1 + 10h
      t3 = Time.parse('2026-05-06T09:00:00')

      expect(steps[0]).to be_a(Sidereal::Scheduler::Schedule::Step::Specific)
      expect(steps[0].at).to eq(t0)

      expect(steps[1]).to be_a(Sidereal::Scheduler::Schedule::Step::Specific)
      expect(steps[1].at).to eq(t1)

      expect(steps[2]).to be_a(Sidereal::Scheduler::Schedule::Step::Recurring)
      expect(steps[2].from).to eq(t1)
      expect(steps[2].to).to eq(t2)             # closed by the duration step

      expect(steps[3]).to be_a(Sidereal::Scheduler::Schedule::Step::Specific)
      expect(steps[3].at).to eq(t2)

      expect(steps[4]).to be_a(Sidereal::Scheduler::Schedule::Step::Specific)
      expect(steps[4].at).to eq(t3)
    end

    it 'leaves a trailing recurring step open-ended (to: nil)' do
      scheduler.schedule 'Forever' do |sc|
        sc.at '2026-05-03T10:00:00', TestSchedFirst
        sc.at 'every minute',        TestSchedSecond
      end

      step = scheduler.schedules.first.steps.last
      expect(step).to be_a(Sidereal::Scheduler::Schedule::Step::Recurring)
      expect(step.to).to be_nil
    end

    it 'a duration as the first step resolves against the Scheduler baseline' do
      scheduler.schedule 'Boot+5m' do |sc|
        sc.at '5m', TestSchedFirst
      end
      step = scheduler.schedules.first.steps.first
      expect(step.at).to eq(t0 + 5 * 60)
    end

    it 'a recurring as the first step has from == baseline and is open-ended' do
      scheduler.schedule 'Forever from boot' do |sc|
        sc.at 'every minute', TestSchedFirst
      end
      step = scheduler.schedules.first.steps.first
      expect(step).to be_a(Sidereal::Scheduler::Schedule::Step::Recurring)
      expect(step.from).to eq(t0)
      expect(step.to).to be_nil
    end
  end

  describe '#tick' do
    it 'fires nothing on the first tick (window is empty)' do
      scheduler.schedule 'A' do |sc|
        sc.at 'every minute', TestSchedRun, n: 1
      end
      scheduler.tick(t0)
      expect(store.appended).to be_empty
    end

    it 'materialises the step via klass.parse and stamps producer + schedule_name metadata' do
      scheduler.schedule 'My sched' do |sc|
        sc.at 'every minute', TestSchedRun, n: 7
      end
      scheduler.tick(t0)
      scheduler.tick(t0 + 60)

      expect(store.appended.size).to eq(1)
      msg = store.appended.first
      expect(msg).to be_a(TestSchedRun)
      expect(msg.payload.n).to eq(7)
      expect(msg.metadata[:producer]).to eq("Schedule #0 'My sched' step #0 (every minute)")
      expect(msg.metadata[:schedule_name]).to eq('My sched')
    end

    it 'fires each step at most once per tick (no catch-up)' do
      scheduler.schedule 'A' do |sc|
        sc.at 'every minute', TestSchedRun, n: 1
      end
      scheduler.tick(t0)
      scheduler.tick(t0 + 5 * 60 + 30)
      expect(store.appended.size).to eq(1)
    end

    it 'a one-off ISO8601 expression fires exactly once and does not refire' do
      scheduler.schedule 'Once' do |sc|
        sc.at (t0 + 60).iso8601, TestSchedRun, n: 1
      end
      scheduler.tick(t0)            # warm-up; window empty
      scheduler.tick(t0 + 120)      # specific instant in window — fires
      scheduler.tick(t0 + 240)
      scheduler.tick(t0 + 3600)

      expect(store.appended.count { |m| m.is_a?(TestSchedRun) }).to eq(1)
    end

    it 'a bound-only marker step never appends to the store, even when its instant is in the window' do
      scheduler.schedule 'Marker' do |sc|
        sc.at (t0 + 60).iso8601         # marker — no klass
        sc.at 'every minute', TestSchedRun, n: 1
      end

      scheduler.tick(t0)
      scheduler.tick(t0 + 120)          # marker's instant in window AND a cron boundary

      # Only the recurring fires; no marker dispatch.
      expect(store.appended.size).to eq(1)
      expect(store.appended.first).to be_a(TestSchedRun)
    end

    it 'logs and continues when one append raises' do
      flaky = Class.new(RecordingStore) do
        def append(msg)
          raise 'boom' if @appended.empty? && msg.is_a?(TestSchedFirst)
          super
        end
      end.new
      sched = described_class.new(store: flaky, baseline: t0)
      sched.schedule 'A' do |sc|
        sc.at 'every minute', TestSchedFirst
      end
      sched.schedule 'B' do |sc|
        sc.at 'every minute', TestSchedSecond
      end

      sched.tick(t0)
      sched.tick(t0 + 60)

      expect(flaky.appended.size).to eq(1)
      expect(flaky.appended.first).to be_a(TestSchedSecond)
    end
  end

  describe '#tick — Campaign 1 end-to-end' do
    it 'fires each step at the right time and respects the recurring upper bound' do
      scheduler.schedule 'Campaign 1' do |sc|
        sc.at '2026-05-03T10:00:00', TestSchedFirst    # T0
        sc.at '3m',                  TestSchedSecond   # T0 + 3m
        sc.at '*/5 * * * *',           TestSchedThird    # recurring (every 5 minutes) from T1 to T2
        sc.at '10h',                 TestSchedFourth   # T2 = T1 + 10h
        sc.at '2026-05-06T09:00:00', TestSchedFifth    # T3
      end

      campaign_t0 = Time.parse('2026-05-03T10:00:00')
      t1 = campaign_t0 + 3 * 60
      t2 = t1 + 10 * 3600
      t3 = Time.parse('2026-05-06T09:00:00')

      # Tick before T0 — nothing fires.
      scheduler.tick(campaign_t0 - 60)
      expect(store.appended).to be_empty

      # Tick across T0 — TestSchedFirst fires.
      scheduler.tick(campaign_t0 + 1)
      expect(store.appended.last).to be_a(TestSchedFirst)

      # Tick across T1 — TestSchedSecond fires.
      scheduler.tick(t1 + 1)
      expect(store.appended.last).to be_a(TestSchedSecond)

      # During the recurring window, every-5-minute boundaries fire
      # TestSchedThird. Tick over the next 10 minutes.
      scheduler.tick(t1 + 5 * 60 + 10)   # crosses 10:08 (next 5/* boundary at 10:05)
      expect(store.appended.last).to be_a(TestSchedThird)
      scheduler.tick(t1 + 10 * 60 + 10)  # crosses 10:13 (next at 10:10)
      expect(store.appended.last).to be_a(TestSchedThird)
      thirds_count = store.appended.count { |m| m.is_a?(TestSchedThird) }

      # Tick past T2 — TestSchedFourth fires; the recurring window
      # should be closed (no more TestSchedThird).
      scheduler.tick(t2 + 1)
      expect(store.appended.last).to be_a(TestSchedFourth)

      # Far past T2 — no more TestSchedThird.
      scheduler.tick(t2 + 3600)
      expect(store.appended.count { |m| m.is_a?(TestSchedThird) }).to eq(thirds_count)

      # Tick across T3 — TestSchedFifth fires.
      scheduler.tick(t3 + 1)
      expect(store.appended.last).to be_a(TestSchedFifth)
    end
  end

  describe 'fiber lifecycle' do
    it 'fires at least once when started under a real Async task with a fast tick interval' do
      sched = described_class.new(tick_interval: 0.05, store: store)
      sched.schedule 'Tick' do |sc|
        sc.at '* * * * * *', TestSchedRun, n: 1
      end

      Sync do |task|
        sched.start(task)
        sleep 1.2
        task.stop
      end

      expect(store.appended.count { |m| m.is_a?(TestSchedRun) }).to be >= 1
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

    def add_run_schedule(sched)
      sched.schedule 'Tick' do |sc|
        sc.at '* * * * * *', TestSchedRun, n: 1
      end
    end

    it 'does not tick while the elector reports follower' do
      sched = described_class.new(tick_interval: 0.02, store: store, elector: elector)
      add_run_schedule(sched)

      Sync do |task|
        sched.start(task)
        sleep 1.2
        task.stop
      end

      expect(store.appended).to be_empty
    end

    it 'starts ticking on promotion and stops on demotion' do
      sched = described_class.new(tick_interval: 0.02, store: store, elector: elector)
      add_run_schedule(sched)

      Sync do |task|
        sched.start(task)
        sleep 0.1
        expect(store.appended).to be_empty

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
