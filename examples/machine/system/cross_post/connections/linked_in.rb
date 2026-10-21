# frozen_string_literal: true

module CrossPost
  module Connections
    # A LinkedIn member, connected with three-legged OAuth 2.0, posting as
    # themselves or as a page they administer. Tokens last 60 days and can't
    # be refreshed: a week before they expire, the user is asked to
    # reauthorize, and posting carries on until they do.
    #
    #   Started ─▶ authorizing ─on_final authorized─▶ connected ─after 53d: WarnExpiry─▶ expiring ─after 7d: Expire─▶ needs_reauth
    #              (Authorizing)  └on_final denied─▶ failed                                           └Reauthorize─▶ authorizing
    #   connected ─ReportRevoked─▶ needs_reauth ─Reauthorize─▶ authorizing
    #   failed ─Retry─▶ authorizing
    #   any but disconnected ─Disconnect─▶ disconnected
    class LinkedIn < Sourced::Machine
      partition_by account_id: Sourced::Types::UUID::V4, connection_id: Sourced::Types::UUID::V4
      message_prefix 'cross_post.connection.linkedin'

      Connected = State(:connected)
      Expiring = State(:expiring)
      NeedsReauth = State(:needs_reauth)
      Failed = State(:failed)
      Disconnected = State(:disconnected)

      LIVE = [Connected, Expiring].freeze

      stopped Disconnected

      WarnExpiry = Command(:warn_expiry)
      Expire = Command(:expire)
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
        after('P53D') do |_ctx, _transition|
          dispatch WarnExpiry
        end

        command WarnExpiry => Expiring
        command ReportRevoked => NeedsReauth
        command Disconnect => Disconnected
      end

      state Expiring do
        after('P7D') do |_ctx, _transition|
          dispatch Expire
        end

        command Expire => NeedsReauth
        command Reauthorize => Authorizing
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
