# frozen_string_literal: true

require 'singleton'

module Sidereal
  module PubSub
    # An in-memory pubsub implementation for testing and development.
    # Thread/fiber-safe. Each subscriber gets its own queue,
    # so a slow consumer won't block other subscribers.
    #
    # Supports NATS-style wildcard subscriptions:
    #   `*` matches exactly one non-empty segment
    #       (e.g. "donations.*" matches "donations.111" but not "donations.111.created")
    #   `>` matches one or more non-empty segments; must be the trailing token
    #       (e.g. "donations.>" matches "donations.111" and "donations.222.created")
    class Memory
      include Singleton

      public_class_method :new

      SEGMENT_SEPARATOR = '.'

      def initialize
        @mutex = Mutex.new
        @subscribers = {}
        @wildcards = []
      end

      # @param pattern [String] exact channel name or wildcard pattern
      # @return [Channel]
      def subscribe(pattern)
        validate_subscription!(pattern)
        channel = Channel.new(name: pattern, pubsub: self)
        @mutex.synchronize do
          if wildcard?(pattern)
            @wildcards = @wildcards + [[compile(pattern), channel]]
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
          if wildcard?(channel.name)
            @wildcards = @wildcards.reject { |_re, ch| ch.equal?(channel) }
          else
            arr = @subscribers[channel.name]
            @subscribers[channel.name] = arr - [channel] if arr
          end
        end
      end

      # @param channel_name [String] concrete channel name (no wildcards)
      # @param event [Sourced::Message]
      # @return [self]
      def publish(channel_name, event)
        validate_publish!(channel_name)
        targets = @mutex.synchronize do
          list = []
          list.concat(@subscribers[channel_name]) if @subscribers[channel_name]
          @wildcards.each { |re, ch| list << ch if re.match?(channel_name) }
          list
        end
        targets.each { |ch| ch << event }
        self
      end

      private

      def wildcard?(name)
        name.split(SEGMENT_SEPARATOR, -1).any? { |seg| seg == '*' || seg == '>' }
      end

      def validate_subscription!(pattern)
        raise ArgumentError, 'channel pattern must not be empty' if pattern.empty?

        segments = pattern.split(SEGMENT_SEPARATOR, -1)
        if segments.any?(&:empty?)
          raise ArgumentError, "empty segment in channel pattern #{pattern.inspect}"
        end

        segments.each_with_index do |seg, i|
          if seg == '>' && i != segments.size - 1
            raise ArgumentError,
                  "`>` wildcard must be the last segment in #{pattern.inspect}"
          end
        end
      end

      def validate_publish!(channel_name)
        raise ArgumentError, 'channel name must not be empty' if channel_name.empty?

        segments = channel_name.split(SEGMENT_SEPARATOR, -1)
        if segments.any?(&:empty?)
          raise ArgumentError, "empty segment in channel name #{channel_name.inspect}"
        end
        if segments.any? { |s| s == '*' || s == '>' }
          raise ArgumentError,
                "wildcards are not allowed when publishing: #{channel_name.inspect}"
        end
      end

      def compile(pattern)
        parts = pattern.split(SEGMENT_SEPARATOR).map do |seg|
          case seg
          when '*' then '[^.]+'
          when '>' then '.+'
          else Regexp.escape(seg)
          end
        end
        Regexp.new('\A' + parts.join('\.') + '\z')
      end

      class Channel
        attr_reader :name

        def initialize(name:, pubsub:)
          @name = name
          @pubsub = pubsub
          @queue = Async::Queue.new
        end

        # Push a message into this channel's queue.
        # @param message [Sourced::Message]
        # @return [self]
        def <<(message)
          @queue << message
          self
        end

        # Block and process messages from the queue.
        # @param handler [#call, nil]
        # @yieldparam message [Sourced::Message]
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
