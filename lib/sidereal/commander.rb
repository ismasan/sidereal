# frozen_string_literal: true

module Sidereal
  class Commander
    CMD_METHOD_PREFIX = '__cmd_'
    CMD_HASH = Types::Hash[type: String, payload?: Hash]
    DEFAULT_CMD_HANDLER = ->(*_) {}
    DEFAULT_MAX_ATTEMPTS = 5

    class << self
      def commander = self

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

      def handle(msg, pubsub:)
        new(pubsub:).handle(msg)
      end

      # Channel name to publish +message+ to.
      # Override on a subclass to route messages to specific channels.
      # Default is 'system'.
      #
      # @param message [Sidereal::Message] command or event being routed
      # @return [String] pubsub channel name
      def channel_name(_message)
        'system'
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
      # @param meta [Sidereal::Store::Meta] attempt number and origin time
      # @return [Sidereal::Store::Result]
      def on_error(exception, _message, meta)
        if meta.attempt < DEFAULT_MAX_ATTEMPTS
          Sidereal::Store::Result::Retry.new(at: Time.now + (2**meta.attempt))
        else
          Sidereal::Store::Result::Fail.new(error: exception)
        end
      end
    end

    def initialize(pubsub:)
      @pubsub = pubsub
      @__current_msg = nil
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
      @pubsub.publish self.class.channel_name(msg), msg
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
