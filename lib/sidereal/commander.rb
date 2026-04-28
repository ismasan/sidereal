# frozen_string_literal: true

module Sidereal
  class Commander
    CMD_METHOD_PREFIX = '__cmd_'
    CMD_HASH = Types::Hash[type: String, payload?: Hash]
    DEFAULT_CMD_HANDLER = ->(*_) {}

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

      def on_error(ex)
        Console.error(self, "Handler error", exception: ex)
        raise ex
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
        dispatched_events.slice(0..),
        dispatched_commands.slice(0..),
      )
    end

    private

    def broadcast(msg_class, payload = {})
      msg = msg_class.new(payload: payload.to_h)
      msg = @__current_msg.correlate(msg)
      @pubsub.publish msg.metadata.fetch(:channel), msg
      self
    end

    def dispatch(msg_class, payload = {})
      msg = msg_class.new(payload: payload.to_h)
      msg = @__current_msg.correlate(msg)
      if self.class.command_registry[msg.class.type]
        dispatched_commands << msg
      else
        dispatched_events << msg
      end
      self
    end

    def dispatched_commands
      @dispatched_commands ||= []
    end

    def dispatched_events
      @dispatched_events ||= []
    end
  end
end
