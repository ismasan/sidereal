# frozen_string_literal: true

module CrossPost
  class Account
    # Account's `active` compound state: whether it takes logins.
    #
    #   open ─LogIn [5th failure]─▶ locked ─after 15m: Unlock─▶ open
    #    └LogIn [password matches] / starts Session
    #
    # A locked account refuses LogIn outright. Resetting the password (an
    # Account command, from either state) also opens it.
    class Active < Sourced::Machine::Part
      part_of Account

      Open = State(:open)
      Locked = State(:locked)

      LogIn = Command(:log_in) do
        attribute :session_id, Sourced::Types::AutoUUID
        attribute :password, Sourced::Types::String.present
      end

      Unlock = Command(:unlock)

      started Open do
        command LogIn => Locked | nil, starts: Session | nil do |profile, cmd|
          if profile.password?(cmd.payload.password)
            start Session, session_id: cmd.payload.session_id
          else
            event LoginFailed
            to Locked if profile.failed_logins >= MAX_FAILED_LOGINS
          end
        end
      end

      state Locked do
        after('15m' => Unlock)

        command Unlock => Open
      end
    end
  end
end
