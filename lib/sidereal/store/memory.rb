# frozen_string_literal: true

require 'singleton'

module Sidereal
  module Store
    class Memory
      include Singleton

      public_class_method :new

      def initialize
        @queue = Async::Queue.new
      end

      # Append a message to the store.
      # Non-blocking — returns immediately regardless of consumers.
      #
      # @param message [Sidereal::Message]
      # @return [true]
      def append(message)
        @queue << message
        true
      end

      # Yield each message as it becomes available (FIFO).
      # Blocks the current fiber between messages. Only one consumer
      # receives any given message. Returns when the fiber is stopped
      # (Async::Stop propagates out of @queue.pop).
      #
      # @yieldparam message [Sidereal::Message]
      def claim_next
        loop do
          yield @queue.pop
        end
      end
    end
  end
end
