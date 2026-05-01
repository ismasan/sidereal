# frozen_string_literal: true

require 'spec_helper'

# -- Test messages --

SchedTick = Sidereal::Message.define('test.sched_tick') do
  attribute :n, Sidereal::Types::Integer
end

SchedNoPayload = Sidereal::Message.define('test.sched_no_payload')

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
    it 'parses the cron and adds an immutable Schedule' do
      scheduler.schedule('* * * * *') {}
      expect(scheduler.schedules.size).to eq(1)
      sch = scheduler.schedules.first
      expect(sch).to be_frozen
      expect(sch.cron_expr).to eq('* * * * *')
    end

    it 'raises ArgumentError on a malformed cron expression' do
      expect { scheduler.schedule('not a cron') {} }.to raise_error(ArgumentError, /invalid cron/)
    end
  end

  describe '#tick' do
    it 'fires nothing on the first tick (window is empty)' do
      scheduler.schedule('* * * * *') { dispatch SchedTick, n: 1 }
      scheduler.tick
      expect(store.appended).to be_empty
    end

    it 'fires a schedule whose next firing falls inside (last_tick_at, now]' do
      scheduler.schedule('* * * * *') { dispatch SchedTick, n: 1 }
      scheduler.tick           # baseline = t0; nothing fires
      advance(60)              # cross one minute boundary
      scheduler.tick
      expect(store.appended.size).to eq(1)
      expect(store.appended.first.payload.n).to eq(1)
    end

    it 'fires each schedule at most once per tick (no catch-up — matches crond)' do
      scheduler.schedule('* * * * *') { dispatch SchedTick, n: 1 }
      scheduler.tick           # baseline tick
      advance(5 * 60 + 30)     # jump 5.5 minutes — 5 boundaries crossed
      scheduler.tick
      expect(store.appended.size).to eq(1)
    end

    it 'continues running when a scheduled block raises' do
      scheduler.schedule('* * * * *') { raise 'boom' }
      scheduler.schedule('* * * * *') { dispatch SchedTick, n: 99 }
      scheduler.tick
      advance(60)
      scheduler.tick
      expect(store.appended.size).to eq(1)
      expect(store.appended.first.payload.n).to eq(99)
    end

    it 'does not mutate registered Schedules across ticks' do
      scheduler.schedule('* * * * *') { dispatch SchedTick, n: 1 }
      original = scheduler.schedules.first
      scheduler.tick
      advance(120)
      scheduler.tick
      expect(scheduler.schedules.first).to eq(original)
    end
  end

  describe 'Run#dispatch' do
    it 'stamps metadata[:producer] with the cron expression on Class+Hash form' do
      scheduler.schedule('5 0 * * *') { dispatch SchedTick, n: 7 }
      scheduler.tick
      advance(24 * 3600)
      scheduler.tick

      msg = store.appended.last
      expect(msg).to be_a(SchedTick)
      expect(msg.payload.n).to eq(7)
      expect(msg.metadata[:producer]).to eq('5 0 * * *')
    end

    it 'supports the bare Class form (no payload)' do
      scheduler.schedule('* * * * *') { dispatch SchedNoPayload }
      scheduler.tick
      advance(60)
      scheduler.tick

      msg = store.appended.last
      expect(msg).to be_a(SchedNoPayload)
      expect(msg.metadata[:producer]).to eq('* * * * *')
    end

    it 'merges :producer into a pre-built Message instance' do
      scheduler.schedule('* * * * *') do
        msg = SchedTick.new(payload: { n: 42 }, metadata: { extra: 'x' })
        dispatch msg
      end
      scheduler.tick
      advance(60)
      scheduler.tick

      msg = store.appended.last
      expect(msg.payload.n).to eq(42)
      expect(msg.metadata[:producer]).to eq('* * * * *')
      expect(msg.metadata[:extra]).to eq('x')
    end

    # Validation paths — Run#dispatch must refuse to enqueue invalid commands.
    # The raise is caught by Scheduler#fire (logged), so the schedule itself
    # keeps running but nothing reaches the store.
    it 'raises Plumb::ParseError when Class+Hash form has an invalid payload' do
      raised = nil
      scheduler.schedule('* * * * *') do
        begin
          dispatch SchedTick, n: 'not_an_integer'
        rescue Plumb::ParseError => ex
          raised = ex
        end
      end
      scheduler.tick
      advance(60)
      scheduler.tick

      expect(raised).to be_a(Plumb::ParseError)
      expect(raised.message).to include('Integer')
      expect(store.appended).to be_empty
    end

    it 'raises Plumb::ParseError when bare Class form omits required payload attrs' do
      raised = nil
      scheduler.schedule('* * * * *') do
        begin
          dispatch SchedTick   # no :n provided, payload defaults to {}
        rescue Plumb::ParseError => ex
          raised = ex
        end
      end
      scheduler.tick
      advance(60)
      scheduler.tick

      expect(raised).to be_a(Plumb::ParseError)
      expect(store.appended).to be_empty
    end

    it 'raises Plumb::ParseError when given a pre-built invalid Message' do
      raised = nil
      scheduler.schedule('* * * * *') do
        begin
          bad = SchedTick.new(payload: {})   # invalid: missing :n
          dispatch bad
        rescue Plumb::ParseError => ex
          raised = ex
        end
      end
      scheduler.tick
      advance(60)
      scheduler.tick

      expect(raised).to be_a(Plumb::ParseError)
      expect(store.appended).to be_empty
    end
  end

  describe 'integration with App.schedule' do
    before { Sidereal.reset_scheduler! }
    after { Sidereal.reset_scheduler! }

    it 'registers on Sidereal.scheduler when called via App.schedule' do
      Class.new(Sidereal::App) do
        schedule '*/5 * * * *' do
          dispatch SchedTick, n: 0
        end
      end
      expect(Sidereal.scheduler.schedules.size).to eq(1)
      expect(Sidereal.scheduler.schedules.first.cron_expr).to eq('*/5 * * * *')
    end
  end

  describe 'fiber lifecycle' do
    it 'fires at least once when started under a real Async task with a fast tick interval' do
      fired = []
      sched = described_class.new(tick_interval: 0.05, store: store)
      sched.schedule('* * * * * *') { fired << Time.now }

      Sync do |task|
        sched.start(task)
        # The very-second cron + 50ms tick should fire within ~1.1s.
        sleep 1.2
        task.stop
      end

      expect(fired.size).to be >= 1
    end
  end
end
