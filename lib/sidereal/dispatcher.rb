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
      @worker_count.times do
        task.async do
          @store.claim_next do |msg|
            commander = @registry[msg.class]
            next if commander.nil?

            result = nil
            begin
              result = commander.handle(msg, pubsub: @pubsub)
            rescue StandardError => ex
              commander.on_error(ex)
            end

            next if result.nil?

            begin
              @pubsub.publish result.msg.metadata.fetch(:channel), result.msg
              result.events.each do |e|
                @pubsub.publish e.metadata.fetch(:channel), e
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
