# frozen_string_literal: true

module CrossPost
  module Connections
    # A Mastodon account, on whichever instance it lives. Its tokens don't
    # expire: it stays connected until the user revokes the app.
    #
    #   Started ─▶ authorizing ─on_final authorized─▶ connected ─ReportRevoked─▶ needs_reauth ─Reauthorize─▶ authorizing
    #              (Authorizing)  └on_final denied─▶ failed ─Retry─▶ authorizing
    #   any but disconnected ─Disconnect─▶ disconnected
    class Mastodon < Sourced::Machine
      partition_by account_id: Sourced::Types::UUID::V4, connection_id: Sourced::Types::UUID::V4
      message_prefix 'cross_post.connection.mastodon'

      Connected = State(:connected)
      NeedsReauth = State(:needs_reauth)
      Failed = State(:failed)
      Disconnected = State(:disconnected)

      LIVE = [Connected].freeze

      stopped Disconnected

      ReportRevoked = Command(:report_revoked)
      Reauthorize = Command(:reauthorize)
      Retry = Command(:retry)
      Disconnect = Command(:disconnect)

      started Authorizing do
        on_final Authorizing::Authorized => Connected
        on_final Authorizing::Denied => Failed

        command Disconnect => Disconnected
      end

      state Connected do
        command ReportRevoked => NeedsReauth
        command Disconnect => Disconnected
      end

      state NeedsReauth do
        command Reauthorize => Authorizing
        command Disconnect => Disconnected
      end

      state Failed do
        command Retry => Authorizing
        command Disconnect => Disconnected
      end
    end
  end
end
