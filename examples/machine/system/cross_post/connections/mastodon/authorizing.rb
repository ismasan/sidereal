# frozen_string_literal: true

module CrossPost
  module Connections
    class Mastodon
      # Mastodon's `authorizing`: every instance is its own OAuth server, so
      # the app registers itself with the user's instance first.
      #
      #   choosing_instance ─ChooseInstance─▶ registering_app ─RegisterApp─▶ redirecting ─ReceiveCode─▶ exchanging_code ─CompleteExchange─▶ authorized (final)
      #          ▲                                 │                         ─DenyAccess─▶ denied (final) ◀─FailExchange─┘
      #          └──────FailRegistration───────────┘                         ─after 10m: Abandon─▶ denied
      class Authorizing < Sourced::Machine::Part
        part_of Mastodon

        ChoosingInstance = State(:choosing_instance)
        RegisteringApp = State(:registering_app)
        Redirecting = State(:redirecting)
        ExchangingCode = State(:exchanging_code)
        Authorized = State(:authorized)
        Denied = State(:denied)

        ChooseInstance = Command(:choose_instance) do
          attribute :domain, Sourced::Types::String.present
        end

        RegisterApp = Command(:register_app) do
          attribute :client_id, Sourced::Types::String.present
        end

        # Not a Mastodon instance, or it's down.
        FailRegistration = Command(:fail_registration) do
          attribute :reason, Sourced::Types::String
        end

        ReceiveCode = Command(:receive_code) do
          attribute :code, Sourced::Types::String.present
        end

        DenyAccess = Command(:deny_access)
        Abandon = Command(:abandon)

        CompleteExchange = Command(:complete_exchange) do
          attribute :acct, Sourced::Types::String.present
        end

        FailExchange = Command(:fail_exchange) do
          attribute :reason, Sourced::Types::String
        end

        started ChoosingInstance do
          command ChooseInstance => RegisteringApp
        end

        state RegisteringApp do
          command RegisterApp => Redirecting
          command FailRegistration => ChoosingInstance
        end

        state Redirecting do
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
