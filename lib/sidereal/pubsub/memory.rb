# frozen_string_literal: true

require 'singleton'
require 'sidereal/single_process'
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
      include SingleProcess

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

      # Subscribe one channel to one or more patterns. A message published on a
      # channel name that matches several of them is delivered to it once.
      #
      # @param patterns [Array<String>] exact channel names or wildcard patterns
      # @return [Channel]
      # @raise [ArgumentError] with no patterns, or an invalid one
      def subscribe(*patterns)
        raise ArgumentError, 'at least one channel pattern is required' if patterns.empty?

        patterns = patterns.uniq
        patterns.each { |pattern| Pattern.validate_subscription!(pattern) }
        channel = Channel.new(patterns:, pubsub: self)
        @mutex.synchronize do
          patterns.each do |pattern|
            if Pattern.wildcard?(pattern)
              @wildcards << [Pattern.compile(pattern), channel]
            else
              (@subscribers[pattern] ||= []) << channel
            end
          end
        end
        channel
      end

      # Remove a channel from the subscriber list.
      # @param channel [Channel]
      def unsubscribe(channel)
        @mutex.synchronize do
          @wildcards.reject! { |_re, ch| ch.equal?(channel) }
          channel.patterns.each do |pattern|
            arr = @subscribers[pattern]
            next unless arr

            arr.delete(channel)
            @subscribers.delete(pattern) if arr.empty?
          end
        end
      end

      # @param channel_name [String] concrete channel name (no wildcards)
      # @param event [Sidereal::Message]
      # @return [self]
      def publish(channel_name, event)
        Pattern.validate_publish!(channel_name)
        targets = @mutex.synchronize do
          exact = @subscribers[channel_name]
          if @wildcards.empty?
            exact && exact.dup
          else
            list = exact ? exact.dup : []
            @wildcards.each { |re, ch| list << ch if re.match?(channel_name) }
            # A channel subscribed to several matching patterns is listed once
            # per pattern. Channels compare by identity.
            list.uniq!
            list.empty? ? nil : list
          end
        end
        targets&.each { |ch| ch << event }
        self
      end

      class Channel
        # @return [Array<String>] the patterns this channel is subscribed to
        attr_reader :patterns

        def initialize(patterns:, pubsub:)
          @patterns = patterns.freeze
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
