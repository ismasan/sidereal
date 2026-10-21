# frozen_string_literal: true

module CrossPost
  module Connections
    # An X (x.com) account, connected with OAuth 2.0 and PKCE. Access tokens
    # last two hours, and the refresh token renews them.
    #
    #   Started ─▶ authorizing ─on_final authorized─▶ connected ─after 2h: Refresh─▶ refreshing ─CompleteRefresh─▶ connected
    #              (Authorizing)  └on_final denied─▶ failed                                       └FailRefresh─▶ needs_reauth
    #   connected ─ReportRevoked─▶ needs_reauth ─Reauthorize─▶ authorizing
    #   failed ─Retry─▶ authorizing
    #   authorizing, connected, needs_reauth, failed ─Disconnect─▶ disconnected
    class X < Sourced::Machine
      partition_by account_id: Sourced::Types::UUID::V4, connection_id: Sourced::Types::UUID::V4
      message_prefix 'cross_post.connection.x'

      ACCESS_TOKEN_TTL = '2h'

      Connected = State(:connected)
      Refreshing = State(:refreshing)
      NeedsReauth = State(:needs_reauth)
      Failed = State(:failed)
      Disconnected = State(:disconnected)

      LIVE = [Connected, Refreshing].freeze

      stopped Disconnected

      Refresh = Command(:refresh)
      CompleteRefresh = Command(:complete_refresh)
      FailRefresh = Command(:fail_refresh)
      # A post was refused with a 401: the user revoked the app on X.
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
        after(ACCESS_TOKEN_TTL) do |_ctx, _transition|
          dispatch Refresh
        end

        command Refresh => Refreshing
        command ReportRevoked => NeedsReauth
        command Disconnect => Disconnected
      end

      state Refreshing do
        command CompleteRefresh => Connected
        command FailRefresh => NeedsReauth
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
