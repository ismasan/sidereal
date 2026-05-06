# frozen_string_literal: true

require 'spec_helper'

# Test message classes used by the dumb-Scheduler tests below.
TestSchedRun = Sidereal::Message.define('test.sched_run') do
  attribute :n, Sidereal::Types::Integer
end

TestSchedEnter = Sidereal::Message.define('test.sched_enter')
TestSchedExit  = Sidereal::Message.define('test.sched_exit')

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

  let(:t0) { Time.local(2026, 5, 4, 12, 0, 0) }

  # Most tests pass an explicit time to +#tick+, so no clock mocking
  # is needed. The fiber-lifecycle and elector tests at the bottom of
  # the file still inject a clock since they exercise the
  # tick-fiber's own scheduling.
  subject(:scheduler) { described_class.new(store: store) }

  describe '#schedule (builder API)' do
    it 'is built incrementally and frozen by Scheduler#schedule' do
      sch = nil
      scheduler.schedule 'Hourly' do |sc|
        sc.run_at '0 * * * *', TestSchedRun, n: 7
        sch = sc
      end

      expect(sch).to be_frozen
      expect(sch.name).to eq('Hourly')
      expect(sch.expression).to eq('0 * * * *')
      expect(sch.run.klass).to eq(TestSchedRun)
      expect(sch.run.payload).to eq(n: 7)
    end

    it 'accepts a pre-built Schedule passed positionally' do
      built = Sidereal::Scheduler::Schedule.new('X')
      built.run_at '* * * * *', TestSchedRun, n: 1

      scheduler.schedule(built)
      expect(scheduler.schedules.size).to eq(1)
      expect(scheduler.schedules.first).to equal(built)
    end

    it 'rejects nil/empty schedule names at construction' do
      expect { Sidereal::Scheduler::Schedule.new(nil) }.to raise_error(ArgumentError, /name is required/)
      expect { Sidereal::Scheduler::Schedule.new('')  }.to raise_error(ArgumentError, /name is required/)
    end

    it 'raises when run_at is missing' do
      expect {
        scheduler.schedule('NoRun') { |_sc| }
      }.to raise_error(ArgumentError, /run_at is required/)
    end

    it 'raises on a malformed expression' do
      expect {
        scheduler.schedule('Bad') do |sc|
          sc.run_at 'not a cron', TestSchedRun, n: 1
        end
      }.to raise_error(ArgumentError, /invalid schedule expression/)
    end

    it 'requires a class on run_at' do
      expect {
        scheduler.schedule('Bare') { |sc| sc.run_at '* * * * *' }
      }.to raise_error(ArgumentError, /run_at requires a command class/)
    end

    it 'coerces enter_at strings to Time' do
      scheduler.schedule 'Strs' do |sc|
        sc.run_at '* * * * *', TestSchedRun, n: 1
        sc.enter_at '2026-06-01T00:00:00Z'
      end
      expect(scheduler.schedules.first.enter_at).to eq(Time.utc(2026, 6, 1))
    end

    it 'accepts a callable exit_at receiving the resolved enter_at' do
      enter = Time.local(2026, 6, 1, 12)
      scheduler.schedule 'Window' do |sc|
        sc.run_at '* * * * *', TestSchedRun, n: 1
        sc.enter_at enter
        sc.exit_at ->(e) { e + 3600 }
      end
      expect(scheduler.schedules.first.exit_at).to eq(enter + 3600)
    end

    it 'raises with a guidance-rich message when exit_at is callable without an enter_at' do
      expect {
        scheduler.schedule 'BadExit' do |sc|
          sc.run_at '* * * * *', TestSchedRun, n: 1
          sc.exit_at ->(e) { e + 60 }
        end
      }.to raise_error(ArgumentError) { |err|
        expect(err.message).to include('"BadExit"')
        expect(err.message).to include('exit_at was given a callable but no enter_at is set')
        expect(err.message).to include('declare enter_at')
        expect(err.message).to include('static Time/String/DateTime')
      }
    end

    it 'accepts a Fugit duration string for exit_at, resolved relative to enter_at' do
      enter = Time.utc(2026, 1, 1, 12, 0, 0)
      scheduler.schedule 'PromoYear' do |sc|
        sc.run_at '0 0 * * *', TestSchedRun, n: 1
        sc.enter_at enter
        sc.exit_at '12y12M', TestSchedExit
      end

      sch = scheduler.schedules.first
      expect(sch.exit_at).to be_a(Time)
      expect(sch.exit_at.year).to eq(2039)
      expect(sch.exit_at.month).to eq(1)
      expect(sch.exit.klass).to eq(TestSchedExit)
    end

    it 'accepts shorter duration strings (e.g. 1h30m) and ISO8601 (P1H30M-style) forms' do
      enter = Time.utc(2026, 1, 1, 12)
      scheduler.schedule 'Hourly' do |sc|
        sc.run_at '* * * * *', TestSchedRun, n: 1
        sc.enter_at enter
        sc.exit_at '1h30m'
      end

      expect(scheduler.schedules.first.exit_at).to eq(enter + 90 * 60)
    end

    it 'raises with a duration-specific message when exit_at is a duration without an enter_at' do
      expect {
        scheduler.schedule 'NoEnter' do |sc|
          sc.run_at '* * * * *', TestSchedRun, n: 1
          sc.exit_at '1h30m'
        end
      }.to raise_error(ArgumentError) { |err|
        expect(err.message).to include('"NoEnter"')
        expect(err.message).to include('exit_at was given a duration but no enter_at is set')
        expect(err.message).to include('Durations are resolved relative to enter_at')
        expect(err.message).to include('declare enter_at')
        expect(err.message).to include('static Time/String/DateTime')
      }
    end

    it 'allows a static exit_at without an enter_at' do
      scheduler.schedule 'BoundedAbove' do |sc|
        sc.run_at '* * * * *', TestSchedRun, n: 1
        sc.exit_at '2026-12-31T00:00:00Z'
      end

      sch = scheduler.schedules.first
      expect(sch.enter_at).to be_nil
      expect(sch.exit_at).to eq(Time.utc(2026, 12, 31))
    end

    it 'raises when both bounds are present and the cron never fires inside the window' do
      expect {
        scheduler.schedule 'TooTight' do |sc|
          sc.run_at '5 0 * * *', TestSchedRun, n: 1
          sc.enter_at Time.local(2026, 6, 1, 12)
          sc.exit_at  Time.local(2026, 6, 1, 12, 30)
        end
      }.to raise_error(ArgumentError, /never fires inside the window/)
    end

    it 'rejects non-String, non-Schedule first argument' do
      expect { scheduler.schedule(42) }.to raise_error(ArgumentError, /expected Schedule or String name/)
    end
  end

  describe '#tick — run dispatch' do
    def schedule_run(scheduler, name: 'My sched', n: 1, exp: '* * * * *')
      scheduler.schedule name do |sc|
        sc.run_at exp, TestSchedRun, n: n
      end
    end

    it 'fires nothing on the first tick (window is empty)' do
      schedule_run(scheduler)
      scheduler.tick(t0)
      expect(store.appended).to be_empty
    end

    it 'materialises the run spec via klass.parse and stamps producer + schedule_name metadata' do
      schedule_run(scheduler, name: 'My sched', n: 7)
      scheduler.tick(t0)
      scheduler.tick(t0 + 60)

      expect(store.appended.size).to eq(1)
      msg = store.appended.first
      expect(msg).to be_a(TestSchedRun)
      expect(msg.payload.n).to eq(7)
      expect(msg.metadata[:producer]).to eq("Schedule #0 'My sched' (* * * * *)")
      expect(msg.metadata[:schedule_name]).to eq('My sched')
    end

    it 'fires each schedule at most once per tick (no catch-up)' do
      schedule_run(scheduler)
      scheduler.tick(t0)
      scheduler.tick(t0 + 5 * 60 + 30)
      expect(store.appended.size).to eq(1)
    end

    it 'fires a one-off date-based run_at exactly once and does not refire' do
      one_off_time = (t0 + 60).iso8601
      scheduler.schedule 'Once' do |sc|
        sc.run_at one_off_time, TestSchedRun, n: 1
      end
      scheduler.tick(t0)            # warm-up; window empty
      scheduler.tick(t0 + 120)      # at-time falls in window, fires
      scheduler.tick(t0 + 240)      # one-off — Fugit::At#next_time returns nil
      scheduler.tick(t0 + 3600)

      expect(store.appended.count { |m| m.is_a?(TestSchedRun) }).to eq(1)
    end

    it 'logs and continues when one append raises' do
      flaky = Class.new(RecordingStore) do
        def append(msg)
          raise 'first one fails' if @appended.empty? && msg.payload.n.zero?
          super
        end
      end.new
      sched = described_class.new(store: flaky)
      schedule_run(sched, name: 'A', n: 0)
      schedule_run(sched, name: 'B', n: 1)

      sched.tick(t0)
      sched.tick(t0 + 60)

      expect(flaky.appended.size).to eq(1)
      expect(flaky.appended.first.payload.n).to eq(1)
    end
  end

  describe '#tick — enter/exit dispatch' do
    it 'dispatches enter when enter_at falls in (baseline, now]' do
      scheduler.schedule 'Promo' do |sc|
        sc.run_at '* * * * *', TestSchedRun, n: 1
        sc.enter_at(t0 + 60, TestSchedEnter)
      end
      scheduler.tick(t0)
      scheduler.tick(t0 + 120)

      enters = store.appended.select { |m| m.is_a?(TestSchedEnter) }
      expect(enters.size).to eq(1)
    end

    it 'dispatches exit when exit_at falls in (baseline, now]' do
      scheduler.schedule 'Promo' do |sc|
        sc.run_at '* * * * *', TestSchedRun, n: 1
        sc.exit_at(t0 + 60, TestSchedExit)
      end
      scheduler.tick(t0)
      scheduler.tick(t0 + 120)

      exits = store.appended.select { |m| m.is_a?(TestSchedExit) }
      expect(exits.size).to eq(1)
    end

    it 'skips run on the same tick that fires enter (exclusive bound when commanded)' do
      scheduler.schedule 'Promo' do |sc|
        sc.run_at '* * * * *', TestSchedRun, n: 1
        sc.enter_at(t0 + 60, TestSchedEnter)
      end
      scheduler.tick(t0)
      # window (t0, t0+120] contains both enter_at and the cron boundary at t0+60
      scheduler.tick(t0 + 120)

      enters = store.appended.count { |m| m.is_a?(TestSchedEnter) }
      runs   = store.appended.count { |m| m.is_a?(TestSchedRun) }
      expect(enters).to eq(1)
      expect(runs).to eq(0)
    end

    it 'skips run on the same tick that fires exit' do
      scheduler.schedule 'Promo' do |sc|
        sc.run_at '* * * * *', TestSchedRun, n: 1
        sc.exit_at(t0 + 60, TestSchedExit)
      end
      scheduler.tick(t0)
      scheduler.tick(t0 + 120)

      exits = store.appended.count { |m| m.is_a?(TestSchedExit) }
      runs  = store.appended.count { |m| m.is_a?(TestSchedRun) }
      expect(exits).to eq(1)
      expect(runs).to eq(0)
    end

    it 'fires enter then exit, each exactly once, with run firing only between them' do
      scheduler.schedule 'Window' do |sc|
        sc.run_at '* * * * *', TestSchedRun, n: 1
        sc.enter_at(t0 + 60, TestSchedEnter)
        sc.exit_at(t0 + 180, TestSchedExit)
      end
      scheduler.tick(t0)             # warm-up
      scheduler.tick(t0 + 90)        # crosses enter at t0+60 (run skipped)
      scheduler.tick(t0 + 150)       # crosses cron boundary at t0+120 (run fires)
      scheduler.tick(t0 + 270)       # crosses exit at t0+180 (run skipped)

      kinds = store.appended.map(&:class)
      expect(kinds.count(TestSchedEnter)).to eq(1)
      expect(kinds.count(TestSchedExit)).to eq(1)
      expect(kinds.count(TestSchedRun)).to eq(1)
      expect(kinds.index(TestSchedEnter)).to be < kinds.index(TestSchedRun)
      expect(kinds.index(TestSchedRun)).to be < kinds.index(TestSchedExit)
    end

    it 'a bound-only enter_at (no command) does not skip run on the boundary tick' do
      scheduler.schedule 'BoundOnly' do |sc|
        sc.run_at '* * * * *', TestSchedRun, n: 1
        sc.enter_at(t0 + 60)
      end
      scheduler.tick(t0)
      scheduler.tick(t0 + 90)

      runs = store.appended.count { |m| m.is_a?(TestSchedRun) }
      expect(runs).to eq(1)
    end

    it 'never fires enter when no enter command is set' do
      scheduler.schedule 'NoEnter' do |sc|
        sc.run_at '* * * * *', TestSchedRun, n: 1
      end
      5.times { |i| scheduler.tick(t0 + i * 60) }
      expect(store.appended.none? { |m| m.is_a?(TestSchedEnter) }).to be true
    end
  end

  describe '#tick — run dispatch with bounds' do
    it 'skips run while now < enter_at' do
      scheduler.schedule 'NotYet' do |sc|
        sc.run_at '* * * * *', TestSchedRun, n: 1
        sc.enter_at(t0 + 60)
      end
      scheduler.tick(t0)
      scheduler.tick(t0 + 30)
      expect(store.appended).to be_empty
    end

    it 'stops firing run once now > exit_at' do
      scheduler.schedule 'Until' do |sc|
        sc.run_at '* * * * *', TestSchedRun, n: 1
        sc.exit_at(t0 + 90)
      end
      scheduler.tick(t0)
      scheduler.tick(t0 + 60)
      expect(store.appended.count { |m| m.is_a?(TestSchedRun) }).to eq(1)

      scheduler.tick(t0 + 180)
      expect(store.appended.count { |m| m.is_a?(TestSchedRun) }).to eq(1)
    end
  end

  describe 'fiber lifecycle' do
    it 'fires at least once when started under a real Async task with a fast tick interval' do
      sched = described_class.new(tick_interval: 0.05, store: store)
      sched.schedule 'Every second' do |sc|
        sc.run_at '* * * * * *', TestSchedRun, n: 1
      end

      Sync do |task|
        sched.start(task)
        sleep 1.2
        task.stop
      end

      runs = store.appended.count { |m| m.is_a?(TestSchedRun) }
      expect(runs).to be >= 1
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
      sched.schedule 'Every second' do |sc|
        sc.run_at '* * * * * *', TestSchedRun, n: 1
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
