# frozen_string_literal: true

require 'async'

module Sidereal
  class Dispatcher
    def self.start(task)
      new(
        worker_count: Sidereal.config.workers,
        store: Sidereal.store,
        registry: Sidereal.registry,
        pubsub: Sidereal.pubsub
      ).start(task)
    end

    def initialize(
      worker_count: Sidereal.config.workers,
      store: Sidereal.store,
      registry: Sidereal.registry,
      pubsub: Sidereal.pubsub,
      channels: Sidereal.channels,
      exceptions: Sidereal.exceptions
    )
      @worker_count = worker_count
      @store = store
      @registry = registry
      @pubsub = pubsub
      @channels = channels
      @exceptions = exceptions
    end

    def start(task)
      @store.start(task)

      @worker_count.times do
        task.async do
          @store.claim_next do |msg, meta|
            commander = @registry[msg.class]
            next Sidereal::Store::Result::Ack if commander.nil?

            begin
              result = commander.handle(msg, pubsub: @pubsub)
              publish(result)
              Sidereal::Store::Result::Ack
            rescue StandardError => ex
              policy_result = begin
                commander.on_error(ex, msg, meta)
              rescue StandardError => ex2
                Console.error(commander, "on_error raised",
                              command: msg.class.name, exception: ex2)
                Sidereal::Store::Result::Fail.new(error: ex)
              end
              log_failure(commander, msg, meta, ex, policy_result)
              dispatch_notification(msg, meta, ex, policy_result)
              policy_result
            end
          end
        end
      end

      self
    end

    def stop
    end

    private

    # Severity tracks the policy decision: a retry is transient (warn),
    # a fail is terminal (error), an ack means the commander chose to
    # swallow (no log — that's its prerogative).
    def log_failure(commander, msg, meta, exception, policy_result)
      case policy_result
      in Sidereal::Store::Result::Retry(at:)
        Console.warn(commander, "command failed, will retry",
                     command: msg.class.name,
                     retry_count: meta.retry_count,
                     retry_at: at,
                     exception: exception)
      in Sidereal::Store::Result::Fail(error:)
        Console.error(commander, "command failed permanently",
                      command: msg.class.name,
                      retry_count: meta.retry_count,
                      exception: error)
      else
        # Ack (commander swallowed) or malformed return — no log here.
      end
    end

    # Hand the failure off to {Sidereal::Exceptions}, which fans out to
    # every registered subscriber (the default UI-toast publisher, plus
    # any APM / logger / custom hooks). Skips when the failing message
    # is itself a System::Notification — guards against a buggy
    # subscriber's exception cascading into another report-and-fan-out
    # loop.
    #
    # All errors during the report are logged and swallowed; a failure
    # to notify must never crash the worker loop.
    def dispatch_notification(msg, meta, exception, policy_result)
      return if msg.is_a?(Sidereal::System::Notification)

      case policy_result
      in Sidereal::Store::Result::Retry(at:)
        @exceptions.report_retry(
          exception:, message: msg, retry_count: meta.retry_count, retry_at: at
        )
      in Sidereal::Store::Result::Fail(error:)
        @exceptions.report_failure(
          exception: error, message: msg, retry_count: meta.retry_count
        )
      else
        nil
      end
    rescue StandardError => ex
      Console.error(self, 'Failed to report exception',
                    command: msg.class.name, exception: ex)
    end

    # Publish failures are logged but do not trigger retry. Handle has
    # already mutated state by this point — retrying would double-apply.
    def publish(result)
      @pubsub.publish @channels.for(result.msg), result.msg
      result.events.each do |e|
        @pubsub.publish @channels.for(e), e
      end
      result.commands.each do |e|
        @store.append e
      end
    rescue StandardError => ex
      Console.error(self, "Publish error", exception: ex)
    end
  end
end
