# frozen_string_literal: true

module Sidereal
  # Publishes a message straight to the pubsub, on the channel
  # {Sidereal::Channels} resolves for it. Nothing is stored and nothing waits
  # for a store transaction, so it suits transient UI updates such as progress
  # indicators. The +sidereal.broadcaster+ component builds one, and any class
  # can inject it with +dep+ (Sourced reactors have it with the Sourced
  # integration; other classes +extend Sidereal::Deps+):
  #
  #   class OrderDecider < Sourced::Decider
  #     dep 'sidereal.broadcaster'
  #
  #     command PlaceOrder do |state, cmd|
  #       broadcaster.broadcast(Working.new, from: cmd)
  #       ...
  #     end
  #   end
  #
  # +from:+ correlates the broadcast to the message being handled, so it
  # resolves to that message's channel and pages reacting to its causal chain
  # see it. {Sidereal::Commander#broadcast} passes the command it's handling.
  class Broadcaster
    # @param pubsub [#publish]
    # @param channels [#for] resolves a message's channel name
    def initialize(pubsub:, channels:)
      @pubsub = pubsub
      @channels = channels
    end

    # @param msg [Sidereal::Message] the message to publish
    # @param from [Sidereal::Message, nil] the message +msg+ is correlated to
    # @return [Sidereal::Message] the published message, correlated if +from+ was given
    def broadcast(msg, from: nil)
      msg = from.correlate(msg) if from
      @pubsub.publish(@channels.for(msg), msg)
      msg
    end
  end
end
