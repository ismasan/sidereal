# frozen_string_literal: true

require 'async'

module Sidereal
  class Dispatcher
    def self.spawn_into(task)
      new(
        worker_count: Sidereal.config.workers,
        store: Sidereal.store,
        registry: Sidereal.registry,
        pubsub: Sidereal.pubsub
      ).spawn_into(task)
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

    def spawn_into(task)
      @store.start(task)
      # Spawn pubsub from the dispatcher's long-lived task so its background
      # fibers (broker, client read loop) outlive any short-lived per-request
      # fiber that might happen to be the first to subscribe or publish.
      @pubsub.start(task)

      @worker_count.times do
        task.async do
          @store.claim_next do |msg|

            commander = @registry[msg.class]
            next if commander.nil?

            result = nil
            begin
              result = commander.handle(msg, pubsub: @pubsub)
            rescue StandardError => ex
              Console.error(commander, "Handler error", exception: ex)
              commander.on_error(ex)
            end

            next if result.nil?

            begin
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
      end

      self
    end

    def stop
    end
  end
end
