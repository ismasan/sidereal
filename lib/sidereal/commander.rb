# frozen_string_literal: true

module Sidereal
  class Commander
    CMD_METHOD_PREFIX = '__cmd_'
    CMD_HASH = Types::Hash[type: String, payload?: Hash]
    DEFAULT_CMD_HANDLER = ->(*_) {}

    class << self
      def command_registry
        @command_registry ||= {}
      end

      def command(*args, &block)
        cmd_class = case args
        in [Class => klass] if klass < Sidereal::Message
          klass
        else
          raise ArgumentError, "unknown arguments #{args.inspect}"
        end

        command_registry[cmd_class.name] = cmd_class
        method_name = Sidereal.message_method_name(CMD_METHOD_PREFIX, cmd_class.name)
        block ||= DEFAULT_CMD_HANDLER
        define_method(method_name, block)
        private(method_name)
        self
      end
    end

    def initialize(pubsub:)
      @pubsub = pubsub
    end

    def from(data)
      data = CMD_HASH.parse(data)
      cmd_class = self.class.command_registry.fetch(data[:type])
      cmd_class.new(data[:payload])
    end

    def handle(cmd)
      method_name = Sidereal.message_method_name(CMD_METHOD_PREFIX, cmd.class.name)
      send(method_name, cmd)
      dispatched_events.slice(0..).each do |msg|
        pubsub.publish cmd.channel, msg
      end

      pubsub.publish cmd.channel, cmd
      # TODO: enqueue dispatched_commands
      # dispatched_commands.slice(0..).each do |c|
      #   c = before_command(c)
      #   handle_command(c)
      # end
    end

    private

    attr_reader :pubsub

    def dispatch(msg)
      if self.class.command_registry[msg.class.name]
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
