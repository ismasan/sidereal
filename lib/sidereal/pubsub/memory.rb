# frozen_string_literal: true

require 'singleton'
require_relative 'pattern'

module Sidereal
  module PubSub
    # An in-memory pubsub implementation for testing and development.
    # Thread/fiber-safe. Each subscriber gets its own queue,
    # so a slow consumer won't block other subscribers.
    #
    # See {Pattern} for the wildcard subscription rules.
    class Memory
      include Singleton

      public_class_method :new

      def initialize
        @mutex = Mutex.new
        @subscribers = {}
        @wildcards = []
      end

      # Lifecycle hook. {Memory} has no background work, so this is a no-op
      # that exists to keep the contract uniform with backends that do
      # (e.g. {Sidereal::PubSub::Unix}).
      def start(_task)
        self
      end

      # @param pattern [String] exact channel name or wildcard pattern
      # @return [Channel]
      def subscribe(pattern)
        Pattern.validate_subscription!(pattern)
        channel = Channel.new(name: pattern, pubsub: self)
        @mutex.synchronize do
          if Pattern.wildcard?(pattern)
            @wildcards = @wildcards + [[Pattern.compile(pattern), channel]]
          else
            @subscribers[pattern] = (@subscribers[pattern] || []) + [channel]
          end
        end
        channel
      end

      # Remove a channel from the subscriber list.
      # @param channel [Channel]
      def unsubscribe(channel)
        @mutex.synchronize do
          if Pattern.wildcard?(channel.name)
            @wildcards = @wildcards.reject { |_re, ch| ch.equal?(channel) }
          else
            arr = @subscribers[channel.name]
            @subscribers[channel.name] = arr - [channel] if arr
          end
        end
      end

      # @param channel_name [String] concrete channel name (no wildcards)
      # @param event [Sidereal::Message]
      # @return [self]
      def publish(channel_name, event)
        Pattern.validate_publish!(channel_name)
        targets = @mutex.synchronize do
          list = []
          list.concat(@subscribers[channel_name]) if @subscribers[channel_name]
          @wildcards.each { |re, ch| list << ch if re.match?(channel_name) }
          list
        end
        targets.each { |ch| ch << event }
        self
      end

      class Channel
        attr_reader :name

        def initialize(name:, pubsub:)
          @name = name
          @pubsub = pubsub
          @queue = Async::Queue.new
        end

        # Push a message into this channel's queue.
        # @param message [Sidereal::Message]
        # @return [self]
        def <<(message)
          @queue << message
          self
        end

        # Block and process messages from the queue.
        # @param handler [#call, nil]
        # @yieldparam message [Sidereal::Message]
        # @yieldparam channel [Channel]
        # @return [self]
        def start(handler: nil, &block)
          handler ||= block

          while (msg = @queue.pop)
            handler.call(msg, self)
          end

          self
        end

        # Stop processing and unsubscribe from the pubsub.
        # @return [self]
        def stop
          @pubsub.unsubscribe(self)
          @queue << nil
          self
        end
      end
    end
  end
end
