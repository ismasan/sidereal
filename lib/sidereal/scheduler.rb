# frozen_string_literal: true

require 'time'   # Time.iso8601, Time.parse
require 'fugit'
require 'async'

module Sidereal
  # In-process cron-driven message dispatcher.
  #
  # Each registered {Schedule} holds:
  # - a parsed expression (cron or natural-language, via +Fugit.parse+),
  # - an optional human-readable +name+,
  # - up to three role specs ({Schedule::RoleSpec}) — +run+ (required),
  #   +enter+ (optional), +exit+ (optional) — each pairing a Message
  #   class with a static payload Hash,
  # - optional +enter_at+ and +exit_at+ wall-clock bounds.
  #
  # On each tick, the Scheduler:
  # - dispatches the +enter+ command iff its instant falls in
  #   +(@last_tick_at, now]+;
  # - dispatches the +exit+ command iff its instant falls in
  #   +(@last_tick_at, now]+;
  # - **otherwise** dispatches the +run+ command iff a cron boundary
  #   falls in the window and the schedule is active at +now+.
  #
  # The "otherwise" is deliberate: when a tick fires +enter+ (or
  # +exit+), we skip +run+ on that same tick so commands handled
  # asynchronously can be ordered correctly — enter strictly before
  # any run, exit strictly after.
  #
  # The Scheduler computes +metadata: { producer:, schedule_name: }+
  # at firing time and dispatches via +klass.parse(payload:, metadata:)+
  # — making no assumption about the message's payload schema and
  # avoiding the Message registry entirely.
  class Scheduler
    DEFAULT_TICK_INTERVAL = 1.0

    # Schedule builder. Mutable until {Scheduler#schedule} calls
    # {#finalize!}, after which it's frozen.
    class Schedule
      RoleSpec = Data.define(:klass, :payload)
      NO_ARG = Object.new.freeze
      private_constant :NO_ARG

      # +Fugit.parse+ returns +EtOrbi::EoTime+ for ISO8601 / date
      # strings — a single instant with no +next_time+. Wrap it so the
      # tick loop sees a uniform "+#next_time(from)+ → Time | nil"
      # interface across cron and one-off expressions.
      class OneOff
        # Wrap +at+ as something responding to +#to_local_time+ so the
        # tick-loop's normalization is uniform. +Fugit.parse+ already
        # returns +EtOrbi::EoTime+ for date strings; for stdlib +Time+
        # passed in directly we build an EoTime via +EtOrbi::EoTime.make+.
        def initialize(at)
          @at = if at.respond_to?(:to_local_time)
                  at
                else
                  EtOrbi::EoTime.make(at)
                end
        end

        def next_time(from)
          return nil if @at < from

          @at
        end
      end
      private_constant :OneOff

      attr_reader :name, :expression, :cron, :enter, :exit

      def initialize(name)
        raise ArgumentError, 'schedule name is required' if name.nil? || name.to_s.empty?

        @name = name
        @expression = nil
        @cron = nil
        @run = nil
        @enter = nil
        @exit = nil
        @enter_at = nil
        @exit_at = nil
        @exit_at_relative_resolver = nil
        @exit_at_relative_kind = nil
      end

      # Recurring (or one-off) schedule expression + the command to
      # dispatch at each firing. The expression is anything
      # +Fugit.parse+ accepts — cron strings, natural-language
      # ("every 3 seconds"), or an ISO8601 date for a one-off.
      #
      # With no args, returns the current run +RoleSpec+ (or nil).
      def run_at(expression = NO_ARG, klass = NO_ARG, **payload)
        return @run if expression.equal?(NO_ARG)
        raise ArgumentError, 'run_at requires a command class' if klass.equal?(NO_ARG)

        @expression = expression
        parsed = Fugit.parse(expression) or raise ArgumentError, "invalid schedule expression: #{expression.inspect}"
        # Cron / interval objects implement #next_time directly; date
        # strings parse to EtOrbi::EoTime (a one-off instant) which
        # we wrap.
        @cron = parsed.respond_to?(:next_time) ? parsed : OneOff.new(parsed)

        @run = RoleSpec.new(klass: klass, payload: payload)
        self
      end

      # @return [RoleSpec, nil] the recurring command spec
      def run = @run

      def enter_at(time = NO_ARG, klass = nil, **payload)
        return @enter_at if time.equal?(NO_ARG)

        @enter_at = coerce_time(time)
        @enter = klass ? RoleSpec.new(klass: klass, payload: payload) : nil
        self
      end

      # exit_at accepts:
      # - a +Time+, +DateTime+, or absolute ISO8601 string — evaluated as-is.
      # - a callable (proc/lambda/method) — invoked at finalize with
      #   the resolved +enter_at+.
      # - an ISO8601 duration string ("P12Y12M") or Fugit duration
      #   ("12y12M", "1h30m", "90s") — added to the resolved
      #   +enter_at+ at finalize.
      #
      # Callable and duration forms both *require* +enter_at+ and
      # raise a guidance-rich error at finalize when it's missing.
      def exit_at(value = NO_ARG, klass = nil, **payload)
        return @exit_at if value.equal?(NO_ARG)

        resolver, kind = relative_exit_at(value)
        if resolver
          @exit_at_relative_resolver = resolver
          @exit_at_relative_kind = kind
        else
          @exit_at = coerce_time(value)
        end
        @exit = klass ? RoleSpec.new(klass: klass, payload: payload) : nil
        self
      end

      # Resolve relative +exit_at+ (callable or duration), validate
      # the window, and freeze. Idempotent.
      def finalize!
        return self if frozen?

        raise ArgumentError, 'schedule run_at is required' unless @run

        if @exit_at_relative_resolver
          unless @enter_at
            kind = @exit_at_relative_kind
            raise ArgumentError,
                  "schedule #{@name.inspect}: exit_at was given a #{kind} but no enter_at is set. " \
                  "#{kind.capitalize}s are resolved relative to enter_at; either declare enter_at, " \
                  'or pass a static Time/String/DateTime to exit_at.'
          end

          @exit_at = coerce_time(@exit_at_relative_resolver.call(@enter_at))
        end

        validate_window!
        freeze
        self
      end

      def active_at?(time)
        return false if @enter_at && time < @enter_at
        return false if @exit_at  && time > @exit_at

        true
      end

      private

      # Detect whether +value+ is a relative exit_at form (callable or
      # a Fugit-parseable duration string). Returns +[resolver_proc,
      # kind]+ or nil. Each resolver, when given the resolved
      # +enter_at+, returns a Time-like (Time, EoTime, DateTime).
      def relative_exit_at(value)
        if value.respond_to?(:call) && !value.is_a?(Time)
          [value, 'callable']
        elsif value.is_a?(String) && (duration = parse_duration(value))
          [->(enter_at) { duration.add_to_time(enter_at) }, 'duration']
        end
      end

      # @return [Fugit::Duration, nil] the parsed duration, or nil if
      #   the string isn't a duration expression.
      def parse_duration(str)
        parsed = Fugit.parse(str)
        parsed.is_a?(Fugit::Duration) ? parsed : nil
      end

      def coerce_time(v)
        case v
        when nil    then nil
        when Time   then v
        when String then Time.parse(v)
        else
          # EtOrbi::EoTime → to_local_time; DateTime → to_time.
          return v.to_local_time if v.respond_to?(:to_local_time)
          return v.to_time       if v.respond_to?(:to_time)

          raise ArgumentError, "expected Time, DateTime, or ISO8601 String; got #{v.inspect}"
        end
      end

      def validate_window!
        return unless @enter_at && @exit_at

        next_fire = @cron.next_time(@enter_at)&.to_local_time
        return if next_fire && next_fire <= @exit_at

        raise ArgumentError,
              "schedule run #{@expression.inspect} ('#{@name}') never fires inside the window [#{@enter_at.iso8601}, #{@exit_at.iso8601}]"
      end
    end

    def initialize(tick_interval: DEFAULT_TICK_INTERVAL, clock: -> { Time.now }, store: nil, elector: nil)
      @tick_interval = tick_interval
      @clock = clock
      @store = store
      @elector = elector            # nil = resolve from Sidereal.elector at start time
      @schedules = []               # registration order
      @last_tick_at = nil
      @tick_fiber = nil
    end

    # Register a schedule. Accepts either a String name (constructs a
    # fresh +Schedule+) or a pre-built +Schedule+ instance. The name
    # is mandatory; empty/nil rejected at the +Schedule+ constructor.
    # The block (when given) builds the schedule via the +Schedule+
    # builder methods (+run_at+, +enter_at+, +exit_at+).
    #
    # @return [self]
    def schedule(name_or_instance)
      sch = case name_or_instance
            when Schedule then name_or_instance
            when String   then Schedule.new(name_or_instance)
            else raise ArgumentError, "expected Schedule or String name; got #{name_or_instance.inspect}"
            end
      yield(sch) if block_given?
      sch.finalize!
      @schedules << sch
      self
    end

    # @return [Array<Schedule>] registered schedules in registration order
    def schedules = @schedules.dup

    def start(task)
      elector = @elector || Sidereal.elector
      elector.on_promote { spawn_tick_fiber(task) }
      elector.on_demote { stop_tick_fiber }
      self
    end

    # @param now [Time] explicit firing instant; defaults to +@clock.call+.
    #   Useful in tests so you don't have to mock the clock — just pass
    #   the time you want the tick to evaluate as.
    def tick(now = @clock.call)
      baseline = @last_tick_at || now
      store = @store || Sidereal.store

      @schedules.each_with_index do |sch, id|
        metadata = build_metadata(sch, id)
        enter_or_exit_fired = false

        if sch.enter && bound_in_window?(sch.enter_at, baseline, now)
          dispatch(store, sch.enter, metadata)
          enter_or_exit_fired = true
        end

        if sch.exit && bound_in_window?(sch.exit_at, baseline, now)
          dispatch(store, sch.exit, metadata)
          enter_or_exit_fired = true
        end

        # Skip run on the same tick that fired enter/exit so the
        # asynchronous worker pool processes them in the desired
        # order: enter strictly before any run, exit strictly after.
        next if enter_or_exit_fired
        next unless sch.active_at?(now)

        # Fugit::At returns nil from +next_time+ once the at-instant has
        # passed — guards against NPE and naturally prevents one-offs
        # from refiring.
        next_at = sch.cron.next_time(baseline)&.to_local_time
        next if next_at.nil? || next_at > now

        dispatch(store, sch.run, metadata)
      end

      @last_tick_at = now
    end

    private

    def bound_in_window?(instant, baseline, now)
      instant && instant > baseline && instant <= now
    end

    # Compute the per-firing metadata. Apps that want a different
    # shape can override this on a Scheduler subclass.
    def build_metadata(sch, id)
      { producer: producer_label(id, sch), schedule_name: sch.name }
    end

    def producer_label(id, sch)
      "Schedule ##{id} '#{sch.name}' (#{sch.expression})"
    end

    def dispatch(store, role_spec, metadata)
      msg = role_spec.klass.parse(payload: role_spec.payload, metadata: metadata)
      store.append(msg)
    rescue StandardError => ex
      Console.error(self, 'failed to dispatch scheduled command',
                    klass: role_spec.klass.name, exception: ex)
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
