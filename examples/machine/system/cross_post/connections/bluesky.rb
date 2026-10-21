# frozen_string_literal: true

module CrossPost
  module Connections
    # A Bluesky account, connected with a handle and an app password. The
    # session's access JWT lasts two hours, and its refresh JWT renews it.
    # There's no denial: wrong credentials go back to the form.
    #
    #   Started ─▶ authorizing ─on_final authorized─▶ connected ─after 2h: Refresh─▶ refreshing ─CompleteRefresh─▶ connected
    #              (Authorizing)                                                    └FailRefresh─▶ needs_reauth
    #   connected ─ReportRevoked─▶ needs_reauth ─Reauthorize─▶ authorizing
    #   authorizing, connected, needs_reauth ─Disconnect─▶ disconnected
    class Bluesky < Sourced::Machine
      partition_by account_id: Sourced::Types::UUID::V4, connection_id: Sourced::Types::UUID::V4
      message_prefix 'cross_post.connection.bluesky'

      ACCESS_JWT_TTL = '2h'

      Connected = State(:connected)
      Refreshing = State(:refreshing)
      NeedsReauth = State(:needs_reauth)
      Disconnected = State(:disconnected)

      LIVE = [Connected, Refreshing].freeze

      stopped Disconnected

      Refresh = Command(:refresh)
      CompleteRefresh = Command(:complete_refresh)
      # The refresh JWT expired, or the app password was deleted.
      FailRefresh = Command(:fail_refresh)
      ReportRevoked = Command(:report_revoked)
      Reauthorize = Command(:reauthorize)
      Disconnect = Command(:disconnect)

      started Authorizing do
        on_final Authorizing::Authorized => Connected

        command Disconnect => Disconnected
      end

      state Connected do
        after(ACCESS_JWT_TTL) do |_ctx, _transition|
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
    end
  end
end
