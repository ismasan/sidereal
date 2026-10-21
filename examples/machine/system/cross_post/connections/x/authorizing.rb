# frozen_string_literal: true

module CrossPost
  module Connections
    class X
      # OAuth 2.0 authorization code flow with PKCE: X's `authorizing`.
      #
      #   redirecting ─ReceiveCode─────▶ exchanging_code ─CompleteExchange─▶ authorized (final)
      #               ─DenyAccess──────▶ denied (final)  ◀─FailExchange──┘
      #               ─after 10m: Abandon─▶ denied
      #
      # The browser is at X's consent screen while redirecting; the callback
      # brings back a code, or an error.
      class Authorizing < Sourced::Machine::Part
        part_of X

        Redirecting = State(:redirecting)
        ExchangingCode = State(:exchanging_code)
        Authorized = State(:authorized)
        Denied = State(:denied)

        # The OAuth callback, with a code and the state it was sent with.
        ReceiveCode = Command(:receive_code) do
          attribute :code, Sourced::Types::String.present
          attribute :state, Sourced::Types::String.present
        end

        # The OAuth callback, with error=access_denied.
        DenyAccess = Command(:deny_access)
        Abandon = Command(:abandon)

        CompleteExchange = Command(:complete_exchange) do
          attribute :handle, Sourced::Types::String.present
          attribute :scopes, Sourced::Types::Array[Sourced::Types::String]
        end

        FailExchange = Command(:fail_exchange) do
          attribute :reason, Sourced::Types::String
        end

        started Redirecting do
          after('10m') do |_ctx, _transition|
            dispatch Abandon
          end

          command ReceiveCode => ExchangingCode
          command DenyAccess => Denied
          command Abandon => Denied
        end

        state ExchangingCode do
          command CompleteExchange => Authorized
          command FailExchange => Denied
        end

        final Authorized
        final Denied
      end
    end
  end
end
