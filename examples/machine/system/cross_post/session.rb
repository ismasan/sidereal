# frozen_string_literal: true

module CrossPost
  # A login, started by Account's LogIn. It lasts 30 days, until the user
  # logs out, or until the account revokes it (a password change).
  #
  #   Started ─▶ active ─LogOut──▶ logged_out
  #                     ─Expire──▶ expired      (after 30 days)
  #                     ─Revoke──▶ revoked
  #
  # Suspending or closing the account stops it: logged_out.
  class Session < Sourced::Machine
    partition_by account_id: Sourced::Types::UUID::V4, session_id: Sourced::Types::UUID::V4
    message_prefix 'cross_post.session'

    Active = State(:active)
    LoggedOut = State(:logged_out)
    Expired = State(:expired)
    Revoked = State(:revoked)

    stopped LoggedOut

    LogOut = Command(:log_out)
    Expire = Command(:expire)
    Revoke = Command(:revoke)

    started Active do
      after('P30D' => Expire)

      command LogOut => LoggedOut
      command Expire => Expired
      command Revoke => Revoked
    end

    final Expired
    final Revoked
  end
end
