# frozen_string_literal: true

module CrossPost
  class Account
    # Account's `verifying` compound state: waiting for the email link.
    #
    #   awaiting_click ─VerifyEmail [token matches]─▶ verified (final)
    #     ▲   └ after 24h ─ExpireLink─▶ link_expired
    #     └──────ResendVerificationLink──────┘
    #
    # Resending from awaiting_click re-enters it: a new link, and a new 24
    # hours. verified is the root final that Account maps to active.
    class Verifying < Sourced::Machine::Part
      part_of Account

      AwaitingClick = State(:awaiting_click)
      LinkExpired = State(:link_expired)
      Verified = State(:verified)

      # From the link in the email.
      VerifyEmail = Command(:verify_email) do
        attribute :token, Sourced::Types::String.present
      end

      ResendVerificationLink = Command(:resend_verification_link)
      ExpireLink = Command(:expire_verification_link)

      started AwaitingClick do
        after('24h') do |_profile, _transition|
          dispatch ExpireLink
        end

        command VerifyEmail => Verified | nil do |profile, cmd|
          to Verified if profile.verification_token == cmd.payload.token
        end

        command ResendVerificationLink => AwaitingClick do
          event VerificationLinkSent, token: SecureRandom.hex(16)
        end

        command ExpireLink => LinkExpired
      end

      # A click on the old link is refused: only a new one verifies.
      state LinkExpired do
        command ResendVerificationLink => AwaitingClick do
          event VerificationLinkSent, token: SecureRandom.hex(16)
        end
      end

      final Verified
    end
  end
end
