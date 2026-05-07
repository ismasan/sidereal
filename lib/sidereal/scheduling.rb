# frozen_string_literal: true

module Sidereal
  # Mixin for hosts (typically {Sidereal::Commander}) that exposes a
  # +schedule+ class macro. The macro generates per-step command
  # classes under +<HostCommander>::Schedules+, defines regular
  # command handlers for them, and registers a +Schedule+ with
  # {Sidereal.scheduler}.
  module Scheduling
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
    # call +at+ once per step. Each +at+ accepts either a block (the
    # macro generates a per-step command class with the block as
    # handler) or an explicit class + payload kwargs (passed straight
    # through to the lower-level Scheduler).
    class ScheduleBuilder
      Entry = Data.define(:expression, :klass, :payload, :block)

      attr_reader :entries

      def initialize
        @entries = []
      end

      # Three call shapes:
      # - +at(expr) { |cmd| ... }+ — block; macro generates a per-step
      #   command class and wires the block as its handler.
      # - +at(expr, klass, **payload)+ — explicit class; pass-through.
      # - +at(expr)+ — bound-only marker; anchors the timeline without
      #   dispatching anything (only valid for specific/duration
      #   expressions; the lower-level Scheduler raises on a
      #   recurring marker at finalize).
      def at(expression, klass = nil, **payload, &block)
        if klass && block
          raise ArgumentError, 'at: pass either a block or a command class, not both'
        end

        @entries << Entry.new(expression: expression, klass: klass, payload: payload, block: block)
      end
    end

    module ClassMethods
      # Class names are prefixed with +Sched+ so the generated
      # constant is always a valid Ruby identifier even when the
      # schedule name begins with a digit.
      SCHEDULE_CLASS_PREFIX = 'Sched'

      # Register a schedule. Two call shapes:
      #
      # @example Multi-step (inner DSL) — block arity 0
      #   schedule 'Tick campaign' do
      #     at '2026-05-06T15:00:00' do |cmd|
      #       # fires once at the boundary
      #     end
      #     at 'every 3 seconds' do |cmd|
      #       # fires recurring until the next concrete bound
      #     end
      #     at '30s' do |cmd|
      #       # fires at start + 30s, closes the recurring
      #     end
      #   end
      #
      # @example Single-step shorthand — block arity 1, expression as 2nd positional
      #   schedule 'Cleanup', '*/5 * * * *' do |cmd|
      #     # equivalent to:
      #     #   schedule 'Cleanup' do
      #     #     at '*/5 * * * *' do |cmd| ... end
      #     #   end
      #   end
      #
      # @example Explicit command classes (multi-step form)
      #   schedule 'Flash sale' do
      #     at '2026-05-10T10:00:00', StartCampaign
      #     at '*/5 * * * *',         LookupResults
      #     at '10h',                 EndCampaign
      #   end
      def schedule(name, expression = nil, &block)
        raise ArgumentError, 'schedule requires a block' unless block
        raise ArgumentError, 'schedule name is required' if name.nil? || name.to_s.empty?

        builder_block = if expression
                          unless block.arity == 1
                            raise ArgumentError,
                                  "schedule #{name.inspect}: shorthand 'schedule(name, expression)' " \
                                  'requires a block of arity 1 (the cmd argument)'
                          end

                          handler = block
                          proc { at(expression, &handler) }
                        else
                          unless block.arity.zero?
                            raise ArgumentError,
                                  "schedule #{name.inspect}: block must take no arguments; use the inner DSL (at(...))"
                          end
                          block
                        end

        id = (@__schedule_counter ||= -1) + 1
        @__schedule_counter = id

        builder = ScheduleBuilder.new
        builder.instance_eval(&builder_block)
        if builder.entries.empty?
          raise ArgumentError, "schedule #{name.inspect}: block must declare at least one at(...)"
        end

        host = self

        Sidereal.scheduler.schedule(name) do |sc|
          builder.entries.each_with_index do |entry, step_idx|
            if entry.block
              klass = host.send(:__define_step_command, name, id, step_idx)
              host.command(klass, &entry.block)
              sc.at entry.expression, klass
            elsif entry.klass
              sc.at entry.expression, entry.klass, **entry.payload
            else
              # Bound-only marker — no class, no block.
              sc.at entry.expression
            end
          end
        end
        self
      end

      private

      def __define_step_command(name, id, step_idx)
        host_namespace = const_get(:Schedules)
        class_name = "#{SCHEDULE_CLASS_PREFIX}#{Sidereal::Utils.camel_case(name)}#{id}Step#{step_idx}"
        return host_namespace.const_get(class_name, false) if host_namespace.const_defined?(class_name, false)

        type_str = "#{__type_namespace}.schedules.#{Sidereal::Utils.snake_case(name)}_#{id}_step_#{step_idx}"
        # Empty payload — the Scheduler stamps schedule context
        # (producer, schedule_name) into metadata at firing time.
        klass = Sidereal::Message.define(type_str)
        host_namespace.const_set(class_name, klass)
        klass
      end

      # Derive the type-string namespace from the host class name.
      # Strips a trailing +::Commander+ so an App-defined commander
      # named +ChatApp::Commander+ produces +chat_app+ rather than
      # +chat_app_commander+.
      def __type_namespace
        return 'anonymous' if self.name.nil?

        Sidereal::Utils.snake_case(self.name.sub(/::Commander\z/, ''))
      end
    end
  end
end
