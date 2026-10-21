# frozen_string_literal: true

module CrossPost
  module Connections
    class Bluesky
      # Bluesky's `authorizing`: the handle resolves to a DID and its PDS,
      # where the app password creates a session.
      #
      #   awaiting_credentials ─SubmitCredentials─▶ resolving_handle ─ResolveHandle─▶ creating_session ─CreateSession─▶ authorized (final)
      #            ▲                                      │                                 │
      #            └────────FailResolve───────────────────┘◀──────RejectCredentials─────────┘
      class Authorizing < Sourced::Machine::Part
        part_of Bluesky

        AwaitingCredentials = State(:awaiting_credentials)
        ResolvingHandle = State(:resolving_handle)
        CreatingSession = State(:creating_session)
        Authorized = State(:authorized)

        SubmitCredentials = Command(:submit_credentials) do
          attribute :handle, Sourced::Types::String.present
          attribute :app_password, Sourced::Types::String.present
        end

        ResolveHandle = Command(:resolve_handle) do
          attribute :did, Sourced::Types::String.present
          attribute :pds, Sourced::Types::String.present
        end

        # No such handle, or its PDS is unreachable.
        FailResolve = Command(:fail_resolve) do
          attribute :reason, Sourced::Types::String
        end

        CreateSession = Command(:create_session)
        RejectCredentials = Command(:reject_credentials)

        started AwaitingCredentials do
          command SubmitCredentials => ResolvingHandle
        end

        state ResolvingHandle do
          command ResolveHandle => CreatingSession
          command FailResolve => AwaitingCredentials
        end

        state CreatingSession do
          command CreateSession => Authorized
          command RejectCredentials => AwaitingCredentials
        end

        final Authorized
      end
    end
  end
end
