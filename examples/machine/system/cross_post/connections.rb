# frozen_string_literal: true

module CrossPost
  # One machine per service an account can post to, started by Account's
  # ConnectService. They share a shape:
  #
  #   Started ─▶ authorizing ─on_final─▶ connected ─ReportRevoked─▶ needs_reauth ─Reauthorize─▶ authorizing
  #              (Authorizing)                   any ─Disconnect─▶ disconnected
  #
  # and differ where the services do: each authorizing is the service's own
  # handshake part (OAuth with PKCE, app passwords, an instance to pick
  # first), and each keeps its credentials fresh its own way (refresh tokens,
  # tokens that expire with a warning, tokens that don't).
  #
  # Each connection's LIVE states are those a post can be sent from.
  module Connections
    ALL = {
      'x' => X,
      'bluesky' => Bluesky,
      'linkedin' => LinkedIn,
      'mastodon' => Mastodon
    }.freeze

    # +'linkedin'+ => +:LinkedIn+, for the machines named after services.
    def self.constant_name(service) = ALL.fetch(service).name.split('::').last.to_sym
  end
end
