# frozen_string_literal: true

module Sidereal
  # Mixin for hosts (typically {Sidereal::Commander}) that exposes a
  # +schedule+ class macro. The macro generates per-schedule command
  # classes under +<HostCommander>::Schedules+, defines regular command
  # handlers for them, and registers a Schedule with
  # {Sidereal.scheduler}.
  #
  # The Scheduler itself is dumb and message-class-agnostic: it stores
  # +{type:, payload:, metadata:}+ hashes and appends materialised
  # {Sidereal::Message} instances to the store at the right time.
  module Scheduling
    ROLES = [:run, :enter, :exit].freeze

    def self.included(host)
      super

      host.const_set(:Schedules, Module.new)
      host.extend ClassMethods
      # Each subclass gets its own +Schedules+ namespace so different
      # hosts don't collide on identically-named schedules.
      host.singleton_class.prepend(SubclassHook)
    end

    module SubclassHook
      def inherited(subclass)
        super
        subclass.const_set(:Schedules, Module.new) unless subclass.const_defined?(:Schedules, false)
      end
    end

    # Inner DSL for {ClassMethods#schedule}. The block passed to
    # +schedule+ is +instance_eval+'d on a builder so the user can
    # declare +enter_at+ / +run_at+ / +exit_at+.
    #
    # Each role accepts one of three shapes:
    # 1. A block — the macro generates a per-schedule command class
    #    under +<HostCommander>::Schedules+ and wires the block as
    #    that class's handler.
    # 2. An explicit command class + payload kwargs — the macro
    #    passes them straight through to the lower-level
    #    {Sidereal::Scheduler::Schedule}; no class is generated and
    #    no handler is defined (caller wires +command+ themselves).
    # 3. (enter_at / exit_at only) Just a time argument — bound only,
    #    no command at all. The schedule's active window still gates
    #    +run+, but no Enter/Exit signal is dispatched.
    #
    # +run_at+ requires either a block or a class; +enter_at+ and
    # +exit_at+ may legitimately have neither.
    class ScheduleBuilder
      Entry = Data.define(:arg, :block, :klass, :payload)

      attr_reader :entries

      def initialize
        @entries = {}
      end

      def enter_at(time, klass = nil, **payload, &block)
        validate_either!(:enter_at, klass, block)
        @entries[:enter] = Entry.new(arg: time, block: block, klass: klass, payload: payload)
      end

      def run_at(expression, klass = nil, **payload, &block)
        validate_either!(:run_at, klass, block)
        raise ArgumentError, 'run_at requires a block or a command class' unless klass || block

        @entries[:run] = Entry.new(arg: expression, block: block, klass: klass, payload: payload)
      end

      def exit_at(time_or_callable_or_duration, klass = nil, **payload, &block)
        validate_either!(:exit_at, klass, block)
        @entries[:exit] = Entry.new(
          arg: time_or_callable_or_duration, block: block, klass: klass, payload: payload
        )
      end

      private

      def validate_either!(method, klass, block)
        return unless klass && block

        raise ArgumentError, "#{method}: pass either a block or a command class, not both"
      end
    end

    module ClassMethods
      # Register a schedule. The block is +instance_eval+'d on a
      # {ScheduleBuilder} that exposes +enter_at+, +run_at+, and
      # +exit_at+. +run_at+ is required.
      #
      # @example
      #   schedule 'Clock tick' do
      #     enter_at '2026-05-03T10:20:00' do |cmd|
      #       # handler for the auto-generated Enter command
      #     end
      #     run_at 'every 3 seconds' do |cmd|
      #       # handler for the Run command (required)
      #     end
      #     exit_at ->(enter_time) { enter_time + 3600 } do |cmd|
      #       # handler for the Exit command
      #     end
      #   end
      #
      # Per-schedule command classes are generated under
      # +<HostCommander>::Schedules+ with names like +SchedClockTick0Run+,
      # +SchedClockTick0Enter+, +SchedClockTick0Exit+ (where +0+ is the
      # schedule's monotonic registration index).
      def schedule(name, &block)
        raise ArgumentError, 'schedule requires a block' unless block
        raise ArgumentError, 'schedule name is required' if name.nil? || name.to_s.empty?

        id = (@__schedule_counter ||= -1) + 1
        @__schedule_counter = id

        entries = collect_entries(name, &block)
        host = self

        Sidereal.scheduler.schedule(name) do |sc|
          host.send(:apply_role_to_schedule, sc, name, id, :enter, entries[:enter])
          host.send(:apply_role_to_schedule, sc, name, id, :run,   entries[:run])
          host.send(:apply_role_to_schedule, sc, name, id, :exit,  entries[:exit])
        end
        self
      end

      private

      # Translate a captured +Entry+ into a call on the lower-level
      # {Sidereal::Scheduler::Schedule}. Three shapes per role:
      # block (generate class + handler), explicit class (pass
      # through), or bound-only (enter_at / exit_at without command).
      def apply_role_to_schedule(sc, name, id, role, entry)
        return if entry.nil?

        if entry.block
          klass = define_schedule_command(name, id, role)
          command(klass, &entry.block)
          send_role_to_sc(sc, role, entry.arg, klass)
        elsif entry.klass
          send_role_to_sc(sc, role, entry.arg, entry.klass, **entry.payload)
        else
          # No command — bound-only. Only meaningful for enter_at/exit_at;
          # collect_entries already rejects run_at without block-or-class.
          send_role_to_sc(sc, role, entry.arg)
        end
      end

      def send_role_to_sc(sc, role, *args, **kwargs)
        method = role == :run ? :run_at : :"#{role}_at"
        sc.public_send(method, *args, **kwargs)
      end

      # Drive the user's block on a {ScheduleBuilder} and return the
      # captured entries. The block must take no arguments and must
      # call +run_at+ at least once.
      def collect_entries(name, &block)
        unless block.arity.zero?
          raise ArgumentError, "schedule #{name.inspect}: block must take no arguments; use the inner DSL (run_at, enter_at, exit_at)"
        end

        builder = ScheduleBuilder.new
        builder.instance_eval(&block)
        unless builder.entries[:run]
          raise ArgumentError, "schedule #{name.inspect}: block must declare run_at"
        end

        builder.entries
      end

      # Class names are prefixed with +Sched+ so the generated constant
      # is always a valid Ruby identifier even when the schedule name
      # begins with a digit (e.g. +'5 minute'+ → +Sched5Minute0Run+).
      SCHEDULE_CLASS_PREFIX = 'Sched'

      def define_schedule_command(name, id, role)
        host_namespace = const_get(:Schedules)
        class_name = "#{SCHEDULE_CLASS_PREFIX}#{Sidereal::Utils.camel_case(name)}#{id}#{Sidereal::Utils.camel_case(role.to_s)}"
        return host_namespace.const_get(class_name, false) if host_namespace.const_defined?(class_name, false)

        type_str = "#{type_namespace}.schedules.#{Sidereal::Utils.snake_case(name)}_#{id}_#{role}"
        # Empty payload — the Scheduler stamps schedule context
        # (producer, schedule_name) into metadata at firing time.
        klass = Sidereal::Message.define(type_str)
        host_namespace.const_set(class_name, klass)
        klass
      end

      # Derive the type-string namespace from the host class name.
      # Strips a trailing +::Commander+ so an App-defined commander
      # named +ChatApp::Commander+ produces +chat_app+ rather than
      # the noisier +chat_app_commander+.
      def type_namespace
        return 'anonymous' if self.name.nil?

        Sidereal::Utils.snake_case(self.name.sub(/::Commander\z/, ''))
      end
    end
  end
end
