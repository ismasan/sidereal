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
  # Each #tick fires schedules whose next firing falls in the half-open
  # window +(@last_tick_at, now]+. At-most-once-per-tick — matches
  # +crond+'s no-catch-up semantics.
  #
  # @example
  #   class MyApp < Sidereal::App
  #     schedule '5 0 * * *' do
  #       dispatch Cleanup, foo: 'bar'
  #     end
  #   end
  class Scheduler
    DEFAULT_TICK_INTERVAL = 1.0

    # One per cron firing. Holds the firing-specific state and exposes
    # +dispatch+ as the user-facing DSL — the user's block is invoked
    # via +instance_exec+ on the Run.
    class Run
      attr_reader :fire_at

      def initialize(schedule:, fire_at:, store:)
        @schedule = schedule
        @fire_at = fire_at
        @store = store
      end

      def cron_expr = @schedule.cron_expr

      def call
        instance_exec(&@schedule.block)
      end

      def dispatch(*args)
        msg = case args
        in [Class => c, Hash => payload]
          validate!(c.new(payload: payload, metadata: { producer: cron_expr }))
        in [Class => c]
          validate!(c.new(metadata: { producer: cron_expr }))
        in [MessageInterface => m]
          # +with_metadata+ uses defaults for missing attributes, which can
          # mask an invalid input. Validate before merging.
          validate!(m).with_metadata(producer: cron_expr)
        end
        @store.append(msg)
      end

      private

      def validate!(msg)
        raise Plumb::ParseError, msg.errors.inspect unless msg.valid?
        msg
      end
    end

    # Pure data — never mutated for the life of the process.
    Schedule = Data.define(:cron_expr, :cron, :block) do
      def resolve(after:, store:)
        Run.new(schedule: self, fire_at: cron.next_time(after).to_local_time, store: store)
      end
    end

    def initialize(tick_interval: DEFAULT_TICK_INTERVAL, clock: -> { Time.now }, store: nil, elector: nil)
      @tick_interval = tick_interval
      @clock = clock
      @store = store
      @elector = elector            # nil = resolve from Sidereal.elector at start time
      @schedules = []
      @last_tick_at = nil
      @tick_fiber = nil
    end

    # Register a cron-scheduled block. Idempotency on duplicate
    # +(expr, block)+ pairs is not enforced — callers register once at
    # boot.
    #
    # @param cron_expr [String] cron expression (5 or 6 fields)
    # @return [self]
    def schedule(cron_expr, &block)
      cron = Fugit.parse_cron(cron_expr) or raise ArgumentError, "invalid cron: #{cron_expr.inspect}"
      @schedules << Schedule.new(cron_expr: cron_expr, cron: cron, block: block)
      self
    end

    # @return [Array<Schedule>] copy of the registered schedules
    def schedules = @schedules.dup

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

    # Fire any schedule whose next firing falls in +(@last_tick_at, now]+.
    # Public so unit tests can drive ticks with an injected clock.
    def tick
      now = @clock.call
      baseline = @last_tick_at || now
      store = @store || Sidereal.store

      @schedules.each do |sch|
        run = sch.resolve(after: baseline, store: store)
        fire(run) if run.fire_at <= now
      end

      @last_tick_at = now
    end

    private

    def fire(run)
      run.call
    rescue StandardError => ex
      Console.error(self, 'scheduled block raised', cron: run.cron_expr, exception: ex)
    end

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
