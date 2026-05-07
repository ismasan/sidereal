# frozen_string_literal: true

module Sidereal
  # Registry that maps message classes to channel-name resolvers.
  # Owned by Sidereal as a web-framework concern: any backend
  # (Sidereal::Dispatcher, a Sourced bridge, custom dispatchers) consults
  # this single registry to figure out where to publish a message so SSE
  # subscribers on the matching channel receive it.
  #
  # @example Type-specific registration
  #   Sidereal.channels.channel_name(SomeCommand) { |cmd| "things.#{cmd.payload[:thing_id]}" }
  #   Sidereal.channels.channel_name(Cmd1, Cmd2) { |cmd| "..." }
  #
  # @example Catch-all (no message classes)
  #   Sidereal.channels.channel_name { |cmd| "..." }
  #
  # @example Resolution
  #   Sidereal.channels.for(msg) # => "things.42"
  class Channels
    DEFAULT_CHANNEL = 'system'

    # Build a Channels with the framework-internal source-channel bypass
    # pre-installed for {Sidereal::System::NotifyRetry} and
    # {NotifyFailure}. Use this anywhere a fresh registry needs to
    # behave the way {Sidereal.channels} does — most notably in tests
    # that inject their own +channels:+ into the dispatcher instead of
    # mutating the process-global one.
    #
    # @return [Channels]
    def self.with_system_defaults
      new.tap do |c|
        bypass = ->(msg) { msg.metadata[:source_channel] || DEFAULT_CHANNEL }
        c.channel_name(System::NotifyRetry, &bypass)
        c.channel_name(System::NotifyFailure, &bypass)
      end
    end

    def initialize
      reset!
    end

    # Register a channel-name resolver for one or more message classes.
    # With no classes, registers the catch-all that runs when no typed
    # handler matches.
    #
    # @param message_classes [Array<Class>] zero or more message classes
    # @yieldparam msg [Sidereal::Message] the message being routed
    # @yieldreturn [String] the channel name
    # @return [self]
    def channel_name(*message_classes, &block)
      raise ArgumentError, 'block required' unless block

      if message_classes.empty?
        @catch_all = block
      else
        message_classes.each { |klass| @routes[klass] = block }
      end
      self
    end

    # Resolve the channel for a message. O(1) hash lookup on
    # +msg.class+ — does NOT walk ancestors. Falls back to the catch-all
    # if registered, then to {DEFAULT_CHANNEL}. Never raises so a
    # misrouted message becomes visible in normal SSE traffic rather
    # than crashing the worker fiber.
    #
    # @param msg [Sidereal::Message]
    # @return [String]
    def for(msg)
      handler = @routes[msg.class] || @catch_all
      handler ? handler.call(msg) : DEFAULT_CHANNEL
    end

    # Clear all registrations. For test isolation.
    # @return [self]
    def reset!
      @routes = {}
      @catch_all = nil
      self
    end
  end
end
