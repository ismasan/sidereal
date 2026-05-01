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

      # Lifecycle hook called by the dispatcher before any claim_next.
      # Memory store has no shared poller, so this is a no-op.
      def start(_task)
        self
      end

      # Append a message to the store.
      # Non-blocking — returns immediately regardless of consumers.
      #
      # @param message [Sidereal::Message]
      # @return [true]
      def append(message)
        @queue << [message, Time.now]
        true
      end

      # Yield each message as it becomes available (FIFO), with per-claim
      # {Sidereal::Store::Meta}. The block must return a
      # {Sidereal::Store::Result} value:
      #
      #   Result::Ack             — drop (no-op; message has been popped)
      #   Result::Retry.new(at:)  — unsupported in Memory; logs WARN, acks
      #   Result::Fail.new(error:) — unsupported in Memory; logs WARN, drops
      #
      # +meta.attempt+ is always 1 (Memory does not track retries).
      # +meta.first_appended_at+ is the time of the originating {#append}.
      #
      # Blocks the current fiber between messages. Only one consumer
      # receives any given message. Returns when the fiber is stopped
      # (Async::Stop propagates out of @queue.pop).
      #
      # @yieldparam message [Sidereal::Message]
      # @yieldparam meta [Sidereal::Store::Meta]
      # @yieldreturn [Sidereal::Store::Result]
      def claim_next
        loop do
          msg, first_appended_at = @queue.pop
          meta = Meta.new(attempt: 1, first_appended_at: first_appended_at)
          result = yield msg, meta
          handle_result(result, msg)
        end
      end

      private

      def handle_result(result, msg)
        case result
        in Result::Ack
          # success — message already popped, nothing to do
        in Result::Retry(at:)
          Console.warn(self, 'retry not supported in Memory store; treating as ack',
                       message: msg.class.name, at: at)
        in Result::Fail(error:)
          Console.warn(self, 'fail not supported in Memory store; dropping message',
                       message: msg.class.name, error: error.message)
        else
          Console.warn(self, 'malformed claim_next return value; treating as ack',
                       message: msg.class.name, result: result.inspect)
        end
      end
    end
  end
end
