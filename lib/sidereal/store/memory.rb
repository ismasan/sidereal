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

      # Claim the next available message (FIFO).
      # Blocks the current fiber until a message is available.
      # Only one consumer will receive any given message.
      #
      # @yieldparam message [Sidereal::Message]
      def claim_next(&)
        message = @queue.pop
        yield message
      end
    end
  end
end
