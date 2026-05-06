# frozen_string_literal: true

require 'time'   # Time.parse, Time.iso8601
require 'fugit'
require 'async'

module Sidereal
  # In-process step-sequence dispatcher.
  #
  # A {Schedule} is an ordered sequence of moments in time, each
  # paired with a command to dispatch. A "moment" can be a specific
  # datetime, a duration relative to the previous concrete moment, or
  # a recurring expression that fires on every match between its
  # start and the next concrete moment (or forever, if no concrete
  # moment follows).
  #
  # The Scheduler is class-agnostic: at firing time it calls
  # +klass.parse(payload:, metadata:)+ on whatever class the user
  # registered. No assumption about the message's payload schema and
  # no Message-registry lookup.
  class Scheduler
    DEFAULT_TICK_INTERVAL = 1.0

    class Schedule
      NO_ARG = Object.new.freeze
      private_constant :NO_ARG

      module Step
        # A specific instant to fire +klass+ once. +klass+ may be
        # +nil+, in which case the step is a bound-only marker (anchors
        # the timeline without dispatching anything).
        Specific = Data.define(:index, :expression, :at, :klass, :payload) do
          # Fires iff +at+ falls strictly inside +(baseline, now]+
          # AND a +klass+ is set. Bound-only markers never fire.
          def fires_in?(baseline, now)
            return false if klass.nil?

            at > baseline && at <= now
          end
        end

        # A recurring expression bounded by +[from, to)+ (open at the
        # upper end so a cron boundary at exactly +to+ belongs to the
        # closing concrete step, not the recurring).
        Recurring = Data.define(:index, :expression, :cron, :from, :to, :klass, :payload) do
          def fires_in?(baseline, now)
            return false if now < from
            return false if to && now >= to

            window_start = baseline > from ? baseline : from
            next_at = cron.next_time(window_start)&.to_local_time
            return false if next_at.nil?
            return false if next_at > now
            return false if to && next_at >= to

            true
          end
        end
      end

      attr_reader :name, :steps

      def initialize(name)
        raise ArgumentError, 'schedule name is required' if name.nil? || name.to_s.empty?

        @name = name
        @raw_steps = []
        @steps = nil
      end

      # Append a step. Three expression kinds, distinguished by
      # +Fugit.parse+ at finalize:
      # - specific datetime → fires once at that instant.
      # - duration ('3m', '10h', 'P12Y12M') → fires once at
      #   +last_concrete + duration+.
      # - recurring (cron, "every 3 seconds") → fires on each match
      #   between its start and the next concrete bound.
      #
      # The +klass+ is optional for specific and duration steps —
      # omit it to declare a **bound-only marker** that anchors the
      # timeline without dispatching anything (useful as a starting
      # boundary for a following recurring or duration step, or as a
      # closing boundary for a preceding recurring step). Recurring
      # steps require +klass+ since a recurring with no command would
      # fire nothing on every match.
      #
      # Block form is intentionally not supported here — the
      # Scheduler stays class-agnostic. Use {Sidereal::Scheduling}'s
      # +schedule+ macro to auto-generate per-step command classes
      # from blocks.
      def at(expression, klass = nil, **payload, &block)
        if block
          raise ArgumentError,
                'block form is supported only via Sidereal::Scheduling DSL; ' \
                'pass an explicit command class to Schedule#at'
        end

        @raw_steps << { expression: expression, klass: klass, payload: payload }
        self
      end

      # Resolve all steps against +baseline+ and freeze. Idempotent.
      # Validates: no time-travel for specific steps, no consecutive
      # recurring steps, durations resolve to a strictly later
      # concrete time.
      def finalize!(baseline:)
        return self if frozen?

        raise ArgumentError, "schedule #{@name.inspect}: must declare at least one at(...)" if @raw_steps.empty?

        resolved = []
        last_concrete = baseline
        pending_recurring_idx = nil

        @raw_steps.each_with_index do |raw, i|
          step, last_concrete, pending_recurring_idx =
            resolve_step(raw, i, baseline, last_concrete, pending_recurring_idx, resolved)
          resolved << step
        end

        @steps = resolved.freeze
        @baseline_used = baseline
        freeze
        self
      end

      private

      # @return [Array(Step, last_concrete, pending_recurring_idx)] the
      #   resolved step plus updated walk state.
      def resolve_step(raw, idx, baseline, last_concrete, pending_recurring_idx, resolved)
        parsed = parse_expression(raw[:expression], idx)

        case parsed
        when Fugit::Duration
          t = parsed.add_to_time(last_concrete).to_local_time
          if t <= last_concrete
            raise ArgumentError,
                  "schedule #{@name.inspect}: step ##{idx} (#{raw[:expression].inspect}) resolves to " \
                  "#{t.iso8601}, not after the previous concrete time #{last_concrete.iso8601}"
          end
          close_pending_recurring!(resolved, pending_recurring_idx, t)
          step = Step::Specific.new(index: idx, expression: raw[:expression], at: t,
                                    klass: raw[:klass], payload: raw[:payload])
          [step, t, nil]

        when EtOrbi::EoTime
          t = parsed.to_local_time
          # Time-travel guard: only validate when a previous user step
          # actually advanced last_concrete past baseline. The very
          # first user step is allowed to be in the past — it simply
          # never fires.
          if last_concrete > baseline && t <= last_concrete
            raise ArgumentError,
                  "schedule #{@name.inspect}: specific time at step ##{idx} (#{t.iso8601}) " \
                  "must be after the previous concrete time (#{last_concrete.iso8601})"
          end
          close_pending_recurring!(resolved, pending_recurring_idx, t)
          step = Step::Specific.new(index: idx, expression: raw[:expression], at: t,
                                    klass: raw[:klass], payload: raw[:payload])
          [step, t, nil]

        else
          unless parsed.respond_to?(:next_time)
            raise ArgumentError,
                  "schedule #{@name.inspect}: expression at step ##{idx} (#{parsed.class}) " \
                  'does not support next_time'
          end
          if raw[:klass].nil?
            raise ArgumentError,
                  "schedule #{@name.inspect}: recurring step ##{idx} (#{raw[:expression].inspect}) " \
                  'requires a command class — bound-only markers are only meaningful for specific or duration steps'
          end
          if pending_recurring_idx
            raise ArgumentError,
                  "schedule #{@name.inspect}: step ##{idx} (#{raw[:expression].inspect}) is recurring " \
                  "but the previous step (##{pending_recurring_idx}) is also recurring with no closing bound. " \
                  'A concrete (specific or duration) step must separate two recurring steps.'
          end
          step = Step::Recurring.new(index: idx, expression: raw[:expression], cron: parsed,
                                     from: last_concrete, to: nil,
                                     klass: raw[:klass], payload: raw[:payload])
          [step, last_concrete, idx]
        end
      end

      # Coerce the user-supplied expression into something the
      # resolution walk can branch on. Strings go through +Fugit.parse+;
      # +Time+, +DateTime+, +EtOrbi::EoTime+ (and any +#to_time+
      # responder) short-circuit to an EoTime so they hit the specific
      # branch directly.
      def parse_expression(expr, idx)
        case expr
        when EtOrbi::EoTime then expr
        when Time           then EtOrbi::EoTime.make(expr)
        when String
          Fugit.parse(expr) or
            raise ArgumentError, "schedule #{@name.inspect}: invalid expression at step ##{idx}: #{expr.inspect}"
        else
          if expr.respond_to?(:to_time)
            EtOrbi::EoTime.make(expr.to_time)
          else
            raise ArgumentError,
                  "schedule #{@name.inspect}: step ##{idx} expression must be a String, Time, " \
                  "DateTime, or EtOrbi::EoTime; got #{expr.inspect}"
          end
        end
      end

      # Close the pending recurring step (if any) by replacing it in
      # +resolved+ with a copy whose +to+ is set to +t+.
      def close_pending_recurring!(resolved, pending_recurring_idx, t)
        return if pending_recurring_idx.nil?

        prev = resolved[pending_recurring_idx]
        resolved[pending_recurring_idx] = Step::Recurring.new(
          index: prev.index, expression: prev.expression, cron: prev.cron,
          from: prev.from, to: t, klass: prev.klass, payload: prev.payload
        )
      end
    end

    attr_reader :baseline

    def initialize(tick_interval: DEFAULT_TICK_INTERVAL, clock: -> { Time.now }, baseline: nil, store: nil, elector: nil)
      @tick_interval = tick_interval
      @clock = clock
      @baseline = baseline || @clock.call
      @store = store
      @elector = elector
      @schedules = []
      @last_tick_at = nil
      @tick_fiber = nil
    end

    # Register a schedule. Accepts either a String name (constructs a
    # fresh +Schedule+) or a pre-built +Schedule+ instance. The block
    # (when given) builds the schedule via +Schedule#at+.
    def schedule(name_or_instance)
      sch = case name_or_instance
            when Schedule then name_or_instance
            when String   then Schedule.new(name_or_instance)
            else raise ArgumentError, "expected Schedule or String name; got #{name_or_instance.inspect}"
            end
      yield(sch) if block_given?
      sch.finalize!(baseline: @baseline)
      @schedules << sch
      self
    end

    def schedules = @schedules.dup

    def start(task)
      elector = @elector || Sidereal.elector
      elector.on_promote { spawn_tick_fiber(task) }
      elector.on_demote { stop_tick_fiber }
      self
    end

    # @param now [Time] explicit firing instant; defaults to +@clock.call+.
    def tick(now = @clock.call)
      baseline = @last_tick_at || now
      store = @store || Sidereal.store

      @schedules.each_with_index do |sch, schedule_id|
        sch.steps.each do |step|
          next unless step.fires_in?(baseline, now)

          metadata = build_metadata(sch, schedule_id, step)
          dispatch(store, step, metadata)
        end
      end

      @last_tick_at = now
    end

    private

    def build_metadata(sch, schedule_id, step)
      {
        producer: producer_label(schedule_id, sch, step),
        schedule_name: sch.name
      }
    end

    def producer_label(schedule_id, sch, step)
      "Schedule ##{schedule_id} '#{sch.name}' step ##{step.index} (#{step.expression})"
    end

    def dispatch(store, step, metadata)
      msg = step.klass.parse(payload: step.payload, metadata: metadata)
      store.append(msg)
    rescue StandardError => ex
      Console.error(self, 'failed to dispatch scheduled command',
                    klass: step.klass.name, exception: ex)
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
      @last_tick_at = nil
    end
  end
end
