# frozen_string_literal: true

require 'sourced/message'

module Sidereal
  # Sidereal messages are {Sourced::Message}s. Both libraries share one
  # top-level registry rooted at {Sourced::Message}, so a message defined here
  # (or by Sourced) is resolvable from the root — see {Sourced::Message.from}.
  # All the machinery (`define`, `from`, `Payload`, `Registry`, `with_metadata`,
  # `#at`/`#in`, `correlate`, the `UnknownMessageError` / `PastMessageDateError`
  # constants, …) is inherited from the gem.
  class Message < Sourced::Message
  end
end
