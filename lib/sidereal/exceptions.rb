# frozen_string_literal: true

module Sidereal
  # Value object passed to every exception subscriber.
  ExceptionReport = Data.define(:kind, :exception, :message, :retry_count, :retry_at) do
    def retry?   = kind == :retry
    def failure? = kind == :failure
  end

  # Value passed to every +on_fatal+ subscriber: a programming error
  # raised by a subscriber (or by reporting/publishing infrastructure)
  # *while* a report was being delivered — e.g. a channel-name resolver
  # that dereferenced a payload attribute the failed message doesn't
  # have. +report+ is the {ExceptionReport} being delivered when it blew
  # up, or +nil+ when reported from outside a fan-out.
  FatalReport = Data.define(:exception, :report)

  # Process-global registry of exception subscribers.
  #
  # Backends call {#report_retry} or {#report_failure} from inside their
  # retry/fail policy; every registered +on_retry+ / +on_failure+
  # subscriber receives an {ExceptionReport}.
  #
  # A third channel, +on_fatal+, carries the *meta-errors*: a bug in a
  # subscriber itself (e.g. a channel-name resolver that dereferences a
  # missing payload attribute). Those are caught so they never tear down
  # the worker fiber, but routed to {#report_fatal}, which always logs and
  # fans out to +on_fatal+ subscribers — so application authors can
  # forward them to an APM service instead of having them silently
  # swallowed.
  #
  # @example Subscribing
  #   Sidereal.exceptions.on_failure do |report|
  #     Sentry.capture_exception(report.exception,
  #                              extra: report.message.payload.to_h)
  #   end
  #   Sidereal.exceptions.on_fatal do |fatal|
  #     Sentry.capture_exception(fatal.exception)   # a subscriber/resolver bug
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

    # Register a subscriber for *fatal* events — a programming error a
    # retry/failure subscriber (or reporting infrastructure) raised while
    # a report was being delivered. Use this to forward such bugs to an
    # APM service. {#report_fatal} always logs regardless of subscribers,
    # so these are never silent; +on_fatal+ subscribers are additive.
    # @yieldparam fatal [FatalReport]
    # @raise [LockedError] if called after {#lock!}
    # @return [self]
    def on_fatal(&block)
      register(:fatal, block)
    end

    # Fan a retry event out to every registered +on_retry+ subscriber.
    # A subscriber that raises is routed to {#report_fatal} — it never
    # crashes the calling worker fiber, and never blocks later subscribers.
    #
    # @param exception [StandardError] the exception the handler raised
    # @param message [Sidereal::Message] the failed command
    # @param retry_count [Integer] 1-indexed attempt that just failed
    # @param retry_at [Time] when the next attempt is scheduled
    # @return [self]
    def report_retry(exception:, message:, retry_count:, retry_at:)
      fan_out @subs[:retry], ExceptionReport.new(kind: :retry, exception:, message:, retry_count:, retry_at:)
    end

    # Fan a terminal-failure event out to every registered +on_failure+
    # subscriber. A subscriber that raises is routed to {#report_fatal}.
    #
    # @param exception [StandardError]
    # @param message [Sidereal::Message]
    # @param retry_count [Integer]
    # @return [self]
    def report_failure(exception:, message:, retry_count:)
      fan_out @subs[:failure], ExceptionReport.new(kind: :failure, exception:, message:, retry_count:, retry_at: nil)
    end

    # Report a fatal error — an exception raised by a subscriber, or by
    # reporting/publishing infrastructure, while handling another error.
    # ALWAYS logs profusely (an error in error-handling is never silent),
    # then fans out to every +on_fatal+ subscriber. An +on_fatal+
    # subscriber that itself raises is logged and dropped — it is NOT
    # re-reported, so there is no fan-out loop.
    #
    # Public so backends can funnel their own infra failures here (e.g. a
    # dispatcher whose channel resolution or pubsub publish raised).
    #
    # @param exception [StandardError] the error raised while reporting
    # @param report [ExceptionReport, nil] the report being delivered when
    #   it raised, when known
    # @return [self]
    def report_fatal(exception:, report: nil)
      Console.error(self, 'fatal error in exception reporting/publishing',
                    exception:, report_kind: report&.kind)

      fatal = FatalReport.new(exception:, report:)
      @subs[:fatal].each do |sub|
        begin
          sub.call(fatal)
        rescue StandardError => ex
          # Terminal: an on_fatal subscriber must not recurse into report_fatal.
          Console.error(self, 'on_fatal subscriber raised', exception: ex)
        end
      end
      self
    end

    # Close the registry. Subsequent {#on_retry} / {#on_failure} /
    # {#on_fatal} raise {LockedError}. Reads keep working unchanged.
    # @return [self]
    def lock!
      @subs.each_value(&:freeze)
      @locked = true
      self
    end

    # @return [Boolean]
    def locked? = @locked

    # Clear all subscribers and unlock. For test isolation.
    # @return [self]
    def reset!
      @subs = { retry: [], failure: [], fatal: [] }
      @locked = false
      self
    end

    private

    def register(kind, block)
      raise ArgumentError, 'block required' unless block
      raise LockedError, 'exceptions registry is locked; register subscribers during boot' if @locked

      @subs.fetch(kind) << block
      self
    end

    def fan_out(list, report)
      list.each do |sub|
        begin
          sub.call(report)
        rescue StandardError => ex
          report_fatal(exception: ex, report: report)
        end
      end
      self
    end
  end
end
