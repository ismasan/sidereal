# frozen_string_literal: true

module Sidereal
  # Leader election. Modules that should run only on a single elected
  # process per host (or cluster, eventually) inject an Elector and react
  # to +on_promote+ / +on_demote+ transitions.
  #
  # @example
  #   elector.on_promote do
  #     # this process is now leader
  #   end.on_demote do
  #     # this process is no longer leader (or never was)
  #   end
  #   elector.start(task)
  #
  # Callback semantics:
  # * +on_promote(&block)+ — registers the block, then calls it
  #   immediately if currently leader. Fires on every future
  #   follower→leader transition.
  # * +on_demote(&block)+ — registers the block, then calls it
  #   immediately if currently follower (the initial state of a fresh
  #   elector). Fires on every future leader→follower transition.
  #
  # Implementations must call +promote!+ / +demote!+ from {#start}'s
  # election loop. Both are idempotent — repeated calls in the same
  # state are no-ops, so callbacks fire exactly once per transition.
  module Elector
    # Mixin: callback registry + transition gating. Including class
    # owns the +@leader+ ivar and calls +promote!+ / +demote!+ from
    # its election strategy.
    module Callbacks
      def on_promote(&block)
        (@on_promote ||= []) << block
        block.call if leader?
        self
      end

      def on_demote(&block)
        (@on_demote ||= []) << block
        block.call unless leader?
        self
      end

      private

      def promote!
        return if @leader
        @leader = true
        invoke_callbacks(@on_promote, :on_promote)
      end

      def demote!
        return unless @leader
        @leader = false
        invoke_callbacks(@on_demote, :on_demote)
      end

      # A raising callback must not kill the election fiber or prevent
      # sibling callbacks from running — log it and move on. Pubsub's
      # broker setup, for example, can raise EADDRINUSE on a stale
      # socket; that's the caller's problem to surface, not the
      # elector's to crash on.
      def invoke_callbacks(callbacks, kind)
        (callbacks || []).each do |cb|
          cb.call
        rescue StandardError => ex
          Console.error(self, 'elector callback raised', kind: kind, exception: ex)
        end
      end
    end

    # Default elector. Always leader, never demotes. Used by single-
    # process apps where no election is needed (e.g. the Memory store +
    # Memory pubsub default).
    class AlwaysLeader
      include Callbacks

      def initialize
        @leader = true
      end

      def leader? = @leader

      def start(_task)
        self
      end
    end
  end
end
