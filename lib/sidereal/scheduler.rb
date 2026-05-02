# frozen_string_literal: true

require 'fugit'
require 'async'

module Sidereal
  # In-process cron-driven message scheduler.
  #
  # Registered via {App.schedule} (or directly via {#schedule}). Started
  # as a child fiber of the same top-level Async task that hosts the
  # dispatcher and pubsub (see {Sidereal::Falcon::Environment::Service#run}).
  #
  # On each #tick the scheduler walks its registered schedules. For
  # each whose next firing falls in the half-open window
  # +(@last_tick_at, now]+, it dispatches a
  # {Sidereal::System::TriggerSchedule} command into the store. The
  # dispatcher's worker pool — possibly multi-process — claims those
  # commands and runs the schedule's block in a Commander instance via
  # {Schedule#run_in}. This keeps the scheduler tick fiber doing
  # almost no work and lets schedule blocks run in parallel under the
  # standard retry/dead-letter machinery.
  #
  # At-most-once-per-tick — matches +crond+'s no-catch-up semantics.
  #
  # @example
  #   class MyApp < Sidereal::App
  #     schedule '5 0 * * *' do
  #       dispatch Cleanup, foo: 'bar'
  #     end
  #   end
  class Scheduler
    DEFAULT_TICK_INTERVAL = 1.0

    # Pure data — never mutated for the life of the process. The +id+
    # is a stable monotonic integer assigned by {Scheduler#schedule}
    # in registration order, used by +TriggerSchedule.payload.schedule_id+
    # to look the schedule back up at handle time. The +name+ is
    # user-supplied at registration ("Recurring cleanup", etc.) and
    # surfaced on +TriggerSchedule.payload.schedule_name+ and inside
    # the +producer+ metadata hash so dispatched commands carry a
    # readable trail back to the originating schedule.
    Schedule = Data.define(:id, :name, :cron_expr, :cron, :block) do
      # Human-readable identifier stamped on +TriggerSchedule.metadata[:producer]+
      # and inherited by every command dispatched from the schedule
      # block via +Message#correlate+. Single-line string so it can sit
      # comfortably in logs, dead-letter sidecars, and chat messages.
      def producer_label
        "Schedule ##{id} '#{name}' (#{cron_expr})"
      end

      # Execute the schedule's block on +context+ via instance_exec, so
      # the block sees +context+'s methods (typically a Commander
      # instance, exposing +dispatch+, +broadcast+, +pubsub+, etc.).
      # The triggering +cmd+ (the +TriggerSchedule+ being handled) is
      # yielded as the block's argument, so the block can read its
      # +metadata+ (e.g. +cmd.metadata[:producer]+) or +id+ for
      # idempotency keys. Blocks that don't declare a parameter
      # silently discard +cmd+ (proc semantics).
      def run_in(context, cmd)
        context.instance_exec(cmd, &block)
      end
    end

    def initialize(tick_interval: DEFAULT_TICK_INTERVAL, clock: -> { Time.now }, store: nil, elector: nil)
      @tick_interval = tick_interval
      @clock = clock
      @store = store
      @elector = elector            # nil = resolve from Sidereal.elector at start time
      @schedules = {}               # id => Schedule, insertion order = registration order
      @last_tick_at = nil
      @tick_fiber = nil
    end

    # Register a cron-scheduled block. The schedule is assigned the
    # next monotonic integer ID. Multiple blocks may share the same
    # cron expression — each gets its own ID and its own
    # +TriggerSchedule+ on every fire.
    #
    # Two call shapes:
    # - +schedule(cron_expr) { ... }+ — auto-named as +"<id> (<cron_expr>)"+
    # - +schedule(name, cron_expr) { ... }+ — user-supplied name
    #
    # @return [self]
    def schedule(*args, &block)
      name, cron_expr = case args
      in [String => cron_expr]
        [nil, cron_expr]
      in [String => name, String => cron_expr]
        [name, cron_expr]
      else
        raise ArgumentError, "schedule takes (cron_expr) or (name, cron_expr); got #{args.inspect}"
      end

      cron = Fugit.parse_cron(cron_expr) or raise ArgumentError, "invalid cron: #{cron_expr.inspect}"
      id = @schedules.size
      name ||= "#{id} (#{cron_expr})"
      @schedules[id] = Schedule.new(id:, name:, cron_expr:, cron:, block:)
      self
    end

    # @return [Array<Schedule>] registered schedules in registration order
    def schedules = @schedules.values

    # Look up a registered schedule by its integer ID. O(1) hash lookup.
    # @return [Schedule, nil]
    def find(id) = @schedules[id]

    # Wire the tick fiber's lifecycle to the elector: spawn when this
    # process is leader, stop when demoted. With the default
    # {Elector::AlwaysLeader}, +on_promote+ fires immediately on
    # registration and the fiber starts straight away — same behaviour
    # as before electors existed.
    def start(task)
      elector = @elector || Sidereal.elector
      elector.on_promote { spawn_tick_fiber(task) }
      elector.on_demote { stop_tick_fiber }
      self
    end

    # For each schedule whose next firing falls in +(@last_tick_at, now]+,
    # dispatch a +TriggerSchedule+ to the store. Public so unit tests
    # can drive ticks with an injected clock.
    def tick
      now = @clock.call
      baseline = @last_tick_at || now
      store = @store || Sidereal.store

      @schedules.each_value do |sch|
        next_at = sch.cron.next_time(baseline).to_local_time
        next if next_at > now

        begin
          store.append(
            Sidereal::System::TriggerSchedule.new(
              payload: { schedule_id: sch.id, schedule_name: sch.name },
              metadata: { producer: sch.producer_label }
            )
          )
        rescue StandardError => ex
          Console.error(self, 'failed to dispatch TriggerSchedule', schedule_name: sch.name, exception: ex)
        end
      end

      @last_tick_at = now
    end

    private

    def spawn_tick_fiber(task)
      return if @tick_fiber

      @tick_fiber = task.async do
        loop do
          tick
          sleep @tick_interval
        end
      end
    end

    def stop_tick_fiber
      f = @tick_fiber
      @tick_fiber = nil
      f&.stop
      # Reset cursor so the next promotion starts a fresh window — without
      # this, a long demotion would cause a one-shot fire on re-promotion
      # for any cron whose boundary fell during the demotion.
      @last_tick_at = nil
    end
  end
end
