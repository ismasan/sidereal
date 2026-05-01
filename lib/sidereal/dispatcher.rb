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
