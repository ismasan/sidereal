# frozen_string_literal: true

module CrossPost
  module Connections
    class LinkedIn
      # LinkedIn's `authorizing`: OAuth 2.0, then a choice of author, the
      # member or one of the pages they administer.
      #
      #   redirecting ─ReceiveCode─▶ exchanging_code ─CompleteExchange─▶ choosing_author ─ChooseAuthor─▶ authorized (final)
      #               ─DenyAccess─▶ denied (final) ◀─FailExchange─┘
      #               ─after 10m: Abandon─▶ denied
      class Authorizing < Sourced::Machine::Part
        part_of LinkedIn

        Redirecting = State(:redirecting)
        ExchangingCode = State(:exchanging_code)
        ChoosingAuthor = State(:choosing_author)
        Authorized = State(:authorized)
        Denied = State(:denied)

        ReceiveCode = Command(:receive_code) do
          attribute :code, Sourced::Types::String.present
          attribute :state, Sourced::Types::String.present
        end

        DenyAccess = Command(:deny_access)
        Abandon = Command(:abandon)

        # With the member, and the pages they can post as.
        CompleteExchange = Command(:complete_exchange) do
          attribute :member_urn, Sourced::Types::String.present
          attribute :page_urns, Sourced::Types::Array[Sourced::Types::String]
        end

        FailExchange = Command(:fail_exchange) do
          attribute :reason, Sourced::Types::String
        end

        ChooseAuthor = Command(:choose_author) do
          attribute :author_urn, Sourced::Types::String.present
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
          command CompleteExchange => ChoosingAuthor
          command FailExchange => Denied
        end

        state ChoosingAuthor do
          command ChooseAuthor => Authorized
        end

        final Authorized
        final Denied
      end
    end
  end
end
