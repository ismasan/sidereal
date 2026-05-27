# frozen_string_literal: true

module Sidereal
  # Value object passed to every exception subscriber.
  ExceptionReport = Data.define(:kind, :exception, :message, :retry_count, :retry_at) do
    def retry?   = kind == :retry
    def failure? = kind == :failure
  end

  # Process-global registry of exception subscribers.
  #
  # Backends call {#report_retry} or {#report_failure} from inside their
  # retry/fail policy; every registered +on_retry+ / +on_failure+
  # subscriber receives an {ExceptionReport}.
  #
  # @example Subscribing
  #   Sidereal.exceptions.on_failure do |report|
  #     Sentry.capture_exception(report.exception,
  #                              extra: report.message.payload.to_h)
  #   end
  #
  # @example Reporting (from a dispatcher backend)
  #   Sidereal.exceptions.report_retry(
  #     exception: ex, message: msg, retry_count: meta.retry_count, retry_at: at
  #   )
  class Exceptions
    LockedError = Class.new(StandardError)

    # Build an instance with the default UI-toast publisher pair
    # pre-installed. Each publisher builds the corresponding
    # {Sidereal::System::NotifyRetry} / {NotifyFailure} from the report
    # and broadcasts it on the failed command's channel via pubsub —
    # so Pages with the existing default reactions render their toasts
    # without any further wiring.
    #
    # Apps that want a clean slate just call {Exceptions.new}.
    #
    # @return [Exceptions]
    def self.with_default_publisher
      new.tap do |e|
        publisher = ->(report) {
          notify = build_notification(report)
          Sidereal.pubsub.publish(Sidereal.channels.for(report.message), notify)
        }
        e.on_retry(&publisher)
        e.on_failure(&publisher)
      end
    end

    # Translate an {ExceptionReport} into a concrete
    # {Sidereal::System::Notify*} message ready to publish.
    # Public so custom publishers can reuse the payload-building logic.
    #
    # @param report [ExceptionReport]
    # @return [Sidereal::System::NotifyRetry, Sidereal::System::NotifyFailure]
    def self.build_notification(report)
      payload = {
        command_type: report.message.class.type,
        command_id: report.message.id,
        command_payload: report.message.payload&.to_h || {},
        retry_count: report.retry_count,
        error_class: report.exception.class.name,
        error_message: report.exception.message,
        backtrace: report.exception.backtrace || []
      }
      if report.retry?
        Sidereal::System::NotifyRetry.new(
          payload: payload.merge(retry_at: report.retry_at.iso8601(6))
        )
      else
        Sidereal::System::NotifyFailure.new(payload: payload)
      end
    end

    def initialize
      reset!
    end

    # Register a subscriber for retry events.
    # @yieldparam report [ExceptionReport]
    # @raise [LockedError] if called after {#lock!}
    # @return [self]
    def on_retry(&block)
      register(:retry, block)
    end

    # Register a subscriber for terminal failure events.
    # @yieldparam report [ExceptionReport]
    # @raise [LockedError] if called after {#lock!}
    # @return [self]
    def on_failure(&block)
      register(:failure, block)
    end

    # Fan a retry event out to every registered +on_retry+ subscriber.
    # Subscriber exceptions are caught and logged — a buggy subscriber
    # never crashes the calling worker fiber.
    #
    # @param exception [StandardError] the exception the handler raised
    # @param message [Sidereal::Message] the failed command
    # @param retry_count [Integer] 1-indexed attempt that just failed
    # @param retry_at [Time] when the next attempt is scheduled
    # @return [self]
    def report_retry(exception:, message:, retry_count:, retry_at:)
      fan_out @retry_subs, ExceptionReport.new(kind: :retry, exception:, message:, retry_count:, retry_at:)
    end

    # Fan a terminal-failure event out to every registered
    # +on_failure+ subscriber. Subscriber exceptions are caught
    # and logged.
    #
    # @param exception [StandardError]
    # @param message [Sidereal::Message]
    # @param retry_count [Integer]
    # @return [self]
    def report_failure(exception:, message:, retry_count:)
      fan_out @failure_subs, ExceptionReport.new(kind: :failure, exception:, message:, retry_count:, retry_at: nil)
    end

    # Close the registry. Subsequent {#on_retry} / {#on_failure} raise
    # {LockedError}. Reads ({#report_retry} / {#report_failure}) keep
    # working unchanged.
    # @return [self]
    def lock!
      @retry_subs.freeze
      @failure_subs.freeze
      @locked = true
      self
    end

    # @return [Boolean]
    def locked? = @locked

    # Clear all subscribers and unlock. For test isolation.
    # @return [self]
    def reset!
      @retry_subs = []
      @failure_subs = []
      @locked = false
      self
    end

    private

    def register(kind, block)
      raise ArgumentError, 'block required' unless block
      raise LockedError, 'exceptions registry is locked; register subscribers during boot' if @locked

      list = kind == :retry ? @retry_subs : @failure_subs
      list << block
      self
    end

    def fan_out(list, report)
      list.each do |sub|
        begin
          sub.call(report)
        rescue StandardError => ex
          Console.error(self, 'exception subscriber raised',
                        kind: report.kind, exception: ex)
        end
      end
      self
    end
  end
end
