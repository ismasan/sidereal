# frozen_string_literal: true

module Sidereal
  module Store
    # Per-claim metadata yielded as the second arg of {Store#claim_next}.
    # +attempt+ is 1 on first delivery and increments on each {Result::Retry}.
    # +first_appended_at+ is the wall-clock time the message originally
    # entered the store, preserved across retries — useful for "give up
    # after N hours regardless of attempt count" policies.
    Meta = Data.define(:attempt, :first_appended_at)

    # Protocol values returned by the block passed to {Store#claim_next}.
    # The store interprets each value as the next state transition for the
    # claimed message.
    #
    #   Result::Ack             — handler succeeded, drop the message
    #   Result::Retry.new(at:)  — transient failure, re-schedule
    #   Result::Fail.new(error:) — permanent failure, dead-letter
    #
    # +Ack+ is a frozen singleton (no fields, no allocation per claim).
    # Any other return value (including +nil+) is treated as Ack with a
    # WARN log.
    module Result
      Ack = Data.define.new
      Retry = Data.define(:at)
      Fail = Data.define(:error)
    end
  end
end
