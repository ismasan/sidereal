# frozen_string_literal: true

require_relative 'scheduling'

module Sidereal
  class Commander
    include Scheduling
    # :pubsub is resolved from the app-wide Sidereal.config container. The
    # dispatcher still passes its own pubsub (`handle(msg, pubsub: @pubsub)`),
    # which the generated `.new` honors as a caller override. App commanders
    # add their own deps with `include Sidereal.inject(:my_repo)` — these
    # accumulate on top of :pubsub.
    include Sidereal.inject(:pubsub)

    CMD_METHOD_PREFIX = '__cmd_'
    CMD_HASH = Types::Hash[type: String, payload?: Hash]
    DEFAULT_CMD_HANDLER = ->(*_) {}
    DEFAULT_MAX_ATTEMPTS = 5

    class << self
      def commander = self

      # Seed a subclass's command registry from its parent so that
      # subclassing a Commander yields a real superset: the subclass
      # handles everything the parent did, plus whatever it adds. Handler
      # methods are already inherited (they're +define_method+'d), so only
      # the type => class table needs copying. Mirrors {Router.inherited}.
      #
      # +super+ is required: {Scheduling} prepends a +SubclassHook#inherited+
      # that sets up the per-subclass +Schedules+ namespace.
      def inherited(subclass)
        super
        subclass.command_registry.merge!(command_registry)
      end

      def command_registry
        @command_registry ||= {}
      end

      def handled_commands
        command_registry.values
      end

      def command(*args, &block)
        cmd_class = case args
        in [Class => klass] if klass < Sidereal::Message
          klass
        else
          raise ArgumentError, "unknown arguments #{args.inspect}"
        end

        command_registry[cmd_class.type] = cmd_class
        method_name = Sidereal.message_method_name(CMD_METHOD_PREFIX, cmd_class.type)
        block ||= DEFAULT_CMD_HANDLER
        define_method(method_name, &block)
        private(method_name)
        self
      end

      def from(data)
        data = CMD_HASH.parse(data)
        cmd_class = command_registry.fetch(data[:type])
        cmd_class.new(data)
      end

      def handle(msg, **deps)
        new(**deps).handle(msg)
      end

      # Decide what to do with a failed command. Called by the dispatcher
      # when {#handle} raises. Return a {Sidereal::Store::Result} value:
      #
      #   Store::Result::Retry.new(at:)   — re-schedule for another attempt
      #   Store::Result::Fail.new(error:) — give up; dead-letter
      #   Store::Result::Ack              — swallow the error silently
      #
      # Default: exponential backoff up to {DEFAULT_MAX_ATTEMPTS} attempts,
      # then fail. Override on a subclass to customize per-commander policy
      # (e.g. branch on +exception.class+ or +message.class+).
      #
      # @param exception [StandardError]
      # @param message [Sidereal::Message] the command being processed
      # @param meta [Sidereal::Store::Meta] retry_count and origin time
      # @return [Sidereal::Store::Result]
      def on_error(exception, _message, meta)
        if meta.retry_count < DEFAULT_MAX_ATTEMPTS
          Sidereal::Store::Result::Retry.new(at: Time.now + (2**meta.retry_count))
        else
          Sidereal::Store::Result::Fail.new(error: exception)
        end
      end
    end

    def initialize(**rest)
      @__current_msg = nil
      super(**rest)                       # generated initializer assigns @pubsub
    end

    Result = Data.define(:msg, :events, :commands)

    def handle(cmd)
      @__current_msg = cmd
      method_name = Sidereal.message_method_name(CMD_METHOD_PREFIX, cmd.class.type)
      send(method_name, cmd)

      Result.new(
        cmd,
        dispatched_events.slice(0..).map(&:message),
        dispatched_commands.slice(0..).map(&:message),
      )
    end

    private

    def broadcast(msg_class, payload = {})
      msg = msg_class.new(payload: payload.to_h)
      msg = @__current_msg.correlate(msg)
      @pubsub.publish Sidereal.channels.for(msg), msg
      self
    end

    class MessageDispatch
      attr_reader :message

      def initialize(msg)
        @message = msg
      end

      def at(t)
        @message = @message.at(t)
        self
      end

      def in(seconds)
        at(Time.now + seconds)
      end
    end

    def dispatch(msg_class, payload = {})
      msg = msg_class.new(payload: payload.to_h)
      msg = @__current_msg.correlate(msg)
      dsp = MessageDispatch.new(msg)
      if self.class.command_registry[msg.class.type]
        dispatched_commands << dsp
      else
        dispatched_events << dsp
      end
      dsp
    end

    def dispatched_commands
      @dispatched_commands ||= []
    end

    def dispatched_events
      @dispatched_events ||= []
    end
  end
end
