# frozen_string_literal: true

module Sidereal
  class Assets
    # Publishes {Changed} on {CHANNEL} when the digest of any asset in use
    # changes, for live reload in development. The +sidereal.assets.watcher+
    # component builds one, and starts it on the leader process, so it
    # publishes once however many processes serve the app.
    #
    # It checks every {Assets.registries registry} that is locked, which is
    # what happens once a registry has rendered a URL or served a request.
    # A registry still being filled isn't read, since reading it would lock
    # it. Only files whose modification time or size changed are read again.
    class Watcher
      DEFAULT_INTERVAL = 0.3

      # @param pubsub [#publish]
      # @param elector [#on_promote, #on_demote]
      # @param enabled [Boolean] whether {#start} watches at all
      # @param interval [Numeric] seconds between checks
      # @param registries [#call] returns the registries to check
      def initialize(pubsub:, elector:, enabled:, interval: DEFAULT_INTERVAL, registries: -> { Assets.registries })
        @pubsub = pubsub
        @elector = elector
        @enabled = enabled
        @interval = interval
        @registries = registries
        @last = nil
        @fiber = nil
      end

      def enabled? = @enabled

      # Check every +interval+ seconds while this process is the leader.
      # Does nothing unless {#enabled?}.
      #
      # @param task [Async::Task]
      # @return [self]
      def start(task)
        return self unless enabled?

        @elector.on_promote { spawn(task) }
        @elector.on_demote { stop }
        self
      end

      # Stop checking.
      def stop
        fiber = @fiber
        @fiber = nil
        fiber&.stop
        @last = nil
        self
      end

      # Compare the digests of the assets in use with the last check's, and
      # publish {Changed} if any differ. The first check only records them.
      # A registry with a file missing, as while an editor saves it by
      # replacing it, keeps its last digests until the file is back.
      #
      # @return [Boolean] whether it published
      def check
        last = @last || {}.compare_by_identity
        current = {}.compare_by_identity
        @registries.call.select(&:locked?).each do |registry|
          current[registry] = registry.digests
        rescue SystemCallError
          current[registry] = last[registry] if last.key?(registry)
        end
        changed = !@last.nil? && current.any? { |registry, digests| last.key?(registry) && last[registry] != digests }
        @last = current
        @pubsub.publish(CHANNEL, Changed.new) if changed
        changed
      end

      private

      def spawn(task)
        return if @fiber

        # Transient, like the scheduler's tick fiber: an infinite loop must
        # not keep the process from shutting down.
        @fiber = task.async(transient: true) do
          loop do
            begin
              check
            rescue StandardError => ex
              Console.error(self, 'failed to check assets for changes', exception: ex)
            end
            sleep @interval
          end
        end
      end
    end
  end
end
