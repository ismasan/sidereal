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
      pubsub: Sidereal.pubsub
    )
      @worker_count = worker_count
      @store = store
      @registry = registry
      @pubsub = pubsub
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
              publish(commander, result)
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
              dispatch_notification(commander, msg, meta, ex, policy_result)
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
                     attempt: meta.attempt,
                     retry_at: at,
                     exception: exception)
      in Sidereal::Store::Result::Fail(error:)
        Console.error(commander, "command failed permanently",
                      command: msg.class.name,
                      attempt: meta.attempt,
                      exception: error)
      else
        # Ack (commander swallowed) or malformed return — no log here.
      end
    end

    # Append a System::NotifyRetry / NotifyFailure command for the
    # benefit of any handler/page that wants to react to failures.
    # Skipped when:
    #
    # * The failing message is itself a system notification (loop
    #   prevention — a raising NotifyFailure handler should not produce
    #   yet another NotifyFailure for the dropped one).
    # * No commander is registered for the notification class. This is
    #   the test/standalone path: without an App.commander installing
    #   no-op handlers, dispatching would just add orphans to the store
    #   that get silently acked.
    #
    # All errors during dispatch are logged and swallowed — a failure
    # to notify must never crash the worker loop.
    def dispatch_notification(commander, msg, meta, exception, policy_result)
      return if system_notification?(msg)

      notify = build_notification(msg, meta, exception, policy_result)
      return if notify.nil?
      return if @registry[notify.class].nil?

      # Stamp the source command's resolved channel so the user's
      # +channel_name+ resolver doesn't have to handle system messages
      # (whose payload shape differs from domain commands). The base
      # App.channel_name wrapper reads this from metadata for system
      # notifications and falls back to 'system' if not stamped.
      source_channel = commander.channel_name(msg)
      stamped = notify.with_metadata(source_channel: source_channel)

      @store.append(msg.correlate(stamped))
    rescue StandardError => ex
      Console.error(self, "Failed to dispatch system notification",
                    command: msg.class.name, exception: ex)
    end

    def system_notification?(msg)
      msg.is_a?(Sidereal::System::Notification)
    end

    def build_notification(msg, meta, exception, policy_result)
      case policy_result
      in Sidereal::Store::Result::Retry(at:)
        Sidereal::System::NotifyRetry.new(
          payload: notification_payload(msg, meta, exception)
                     .merge(retry_at: at.iso8601(6))
        )
      in Sidereal::Store::Result::Fail(error:)
        Sidereal::System::NotifyFailure.new(
          payload: notification_payload(msg, meta, error)
        )
      else
        nil
      end
    end

    def notification_payload(msg, meta, exception)
      {
        command_type: msg.class.type,
        command_id: msg.id,
        command_payload: msg.payload&.to_h || {},
        attempt: meta.attempt,
        error_class: exception.class.name,
        error_message: exception.message,
        backtrace: exception.backtrace || []
      }
    end

    # Publish failures are logged but do not trigger retry. Handle has
    # already mutated state by this point — retrying would double-apply.
    def publish(commander, result)
      @pubsub.publish commander.channel_name(result.msg), result.msg
      result.events.each do |e|
        @pubsub.publish commander.channel_name(e), e
      end
      result.commands.each do |e|
        @store.append e
      end
    rescue StandardError => ex
      Console.error(self, "Publish error", exception: ex)
    end
  end
end
