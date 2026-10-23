# frozen_string_literal: true

require 'digest'
require 'securerandom'

module CrossPost
  # A user's account: the root of the app. What the user can do depends on
  # where the account is.
  #
  #   initial ─SignUp─▶ verifying ───on_final verified──▶ active ─Suspend─▶ suspended
  #                     ├ awaiting_click ⇄ link_expired  ├ open ⇄ locked     └Reinstate─▶ active (H*)
  #                     └ (verified)                     │
  #   verifying ─PurgeUnverified|CloseAccount─▶ closed  ◀─CloseAccount
  #
  # The compound states are parts: Verifying, until the
  # email link is clicked, and Active, which locks logins after too
  # many failures.
  #
  # An active account starts children, each a machine of its own, in its own
  # stream: a Session per login, a connection per service (Connections::X and
  # the rest, each with its own auth handshake), and a Post per post. Their
  # messages carry account_id, so the account evolves the ones it needs to
  # know about: which services are connected and which posts are drafts.
  # Closing the account stops them all.
  class Account < Sourced::Machine
    partition_by account_id: Sourced::Types::UUID::V4
    message_prefix 'cross_post.account'

    MAX_FAILED_LOGINS = 5

    # ---- States ----

    Suspended = State(:suspended)
    Closed = State(:closed)

    # ---- Commands ----

    SignUp = Command(:sign_up) do
      attribute :account_id, Sourced::Types::AutoUUID
      attribute :email, Sourced::Types::String.present
      attribute :password, Sourced::Types::String.present
    end

    # Ends an account that was never verified. Dispatched 30 days after sign up.
    PurgeUnverified = Command(:purge_unverified)

    RequestPasswordReset = Command(:request_password_reset)

    # From the reset link: the token in it, and the new password.
    ResetPassword = Command(:reset_password) do
      attribute :token, Sourced::Types::String.present
      attribute :password, Sourced::Types::String.present
    end

    # Starts the service's connection machine, at its handshake. One
    # connection per service.
    ConnectService = Command(:connect_service) do
      attribute :connection_id, Sourced::Types::AutoUUID
      attribute :service, Sourced::Types::String.options(SERVICES)
    end

    # Starts a Post, which can go to any service connected now (and to any
    # connected while it's a draft).
    DraftPost = Command(:draft_post) do
      attribute :post_id, Sourced::Types::AutoUUID
    end

    # Staff only.
    Suspend = Command(:suspend) do
      attribute :reason, Sourced::Types::String.present
    end
    Reinstate = Command(:reinstate)

    CloseAccount = Command(:close)

    # ---- Events ----

    SignedUp = Event(:signed_up) do
      attribute :email, Sourced::Types::String
      attribute :password_digest, Sourced::Types::String
    end

    # The mailer sends the link. Each one replaces the last.
    VerificationLinkSent = Event(:verification_link_sent) do
      attribute :token, Sourced::Types::String
    end

    LoginFailed = Event(:login_failed)

    PasswordResetLinkSent = Event(:password_reset_link_sent) do
      attribute :token, Sourced::Types::String
    end

    PasswordChanged = Event(:password_changed) do
      attribute :password_digest, Sourced::Types::String
    end

    # ---- Domain state ----

    class Profile
      attr_accessor :account_id, :email, :password_digest, :verification_token, :reset_token, :failed_logins
      # Session ids; connection_id => service; connection_id => service, while
      # connected; post ids of drafts.
      attr_reader :sessions, :connections, :connected, :drafts

      def initialize
        @failed_logins = 0
        @sessions = Set.new
        @connections = {}
        @connected = {}
        @drafts = Set.new
      end

      def self.digest(password) = Digest::SHA256.hexdigest(password)

      def password?(password) = password_digest == Profile.digest(password)
      def connecting?(service) = connections.value?(service)
      def connected_services = connected.values.uniq
    end

    context { Profile.new }

    before_evolve do |profile, evt|
      profile.account_id = evt.payload.account_id
    end

    evolve SignedUp do |profile, evt|
      profile.email = evt.payload.email
      profile.password_digest = evt.payload.password_digest
    end

    evolve VerificationLinkSent do |profile, evt|
      profile.verification_token = evt.payload.token
    end

    evolve LoginFailed do |profile, _evt|
      profile.failed_logins += 1
    end

    evolve PasswordResetLinkSent do |profile, evt|
      profile.reset_token = evt.payload.token
    end

    evolve PasswordChanged do |profile, evt|
      profile.password_digest = evt.payload.password_digest
      profile.reset_token = nil
      profile.failed_logins = 0
    end

    # ---- Children, as data ----

    evolve Session::Started do |profile, evt|
      profile.sessions << evt.payload.session_id
    end

    evolve Session::Finished do |profile, evt|
      profile.sessions.delete(evt.payload.session_id)
    end

    # Each connection, while it exists, and while it's connected: the
    # states in its LIVE list.
    Connections::ALL.each do |service, connection|
      evolve connection::Started do |profile, evt|
        profile.connections[evt.payload.connection_id] = service
      end

      evolve connection::Finished do |profile, evt|
        profile.connections.delete(evt.payload.connection_id)
        profile.connected.delete(evt.payload.connection_id)
      end

      (connection.transition_classes - [connection::Started]).each do |transition|
        evolve transition do |profile, evt|
          if connection::LIVE.include?(transition)
            profile.connected[evt.payload.connection_id] = service
          else
            profile.connected.delete(evt.payload.connection_id)
          end
        end
      end
    end

    evolve Post::Started do |profile, evt|
      profile.drafts << evt.payload.post_id
    end

    # Back to drafting from scheduled or failed; out of it on any other.
    (Post.transition_classes - [Post::Started]).each do |transition|
      evolve transition do |profile, evt|
        if evt.payload.target.start_with?('drafting')
          profile.drafts << evt.payload.post_id
        else
          profile.drafts.delete(evt.payload.post_id)
        end
      end
    end

    # ---- The statechart ----

    initial do
      command SignUp => Verifying do |_profile, cmd|
        event SignedUp, email: cmd.payload.email, password_digest: Profile.digest(cmd.payload.password)
        event VerificationLinkSent, token: SecureRandom.hex(16)
      end
    end

    state Verifying do
      on_final Verifying::Verified => Active

      after('P30D' => PurgeUnverified)

      command PurgeUnverified => Closed
      command CloseAccount => Closed
    end

    # Starting children is the active account's: a suspended one keeps them,
    # but can't start more.
    state Active do
      command RequestPasswordReset do |_profile, _cmd|
        event PasswordResetLinkSent, token: SecureRandom.hex(16)
      end

      # Unlocks a locked account, too.
      command ResetPassword => Active::Open | nil do |profile, cmd|
        if profile.reset_token == cmd.payload.token
          event PasswordChanged, password_digest: Profile.digest(cmd.payload.password)
          to Active::Open
        end
      end

      command ConnectService, starts: Connections::ALL.values.reduce(:|) | nil do |profile, cmd|
        service = cmd.payload.service
        start Connections::ALL.fetch(service), connection_id: cmd.payload.connection_id unless profile.connecting?(service)
      end

      command DraftPost, starts: Post do |profile, cmd|
        start Post, post_id: cmd.payload.post_id, services: profile.connected_services
      end

      command Suspend => Suspended
      command CloseAccount => Closed
    end

    # Logged out everywhere. Connections and posts stay as they are.
    state Suspended do
      stops Session

      command Reinstate => Active.history(deep: true)
      command CloseAccount => Closed
    end

    final Closed do
      stops Session
      stops Post
      Connections::ALL.each_value { stops it }
    end

    # ---- Reactions ----

    # A new password logs every session out.
    reaction PasswordChanged do |profile, _evt|
      profile.sessions.each { dispatch Session::Revoke, session_id: it }
      nil
    end

    # Drafts hear about services as they connect and drop off: the regions of
    # Post's drafting can only select a connected service.
    Connections::ALL.each do |service, connection|
      targets = Post::Targets::ALL.fetch(service)

      reaction connection::Connected do |profile, _evt|
        profile.drafts.each { dispatch targets::Enable, post_id: it }
        nil
      end

      [connection::NeedsReauth, connection::Disconnected].each do |offline|
        reaction offline do |profile, _evt|
          profile.drafts.each { dispatch targets::Disable, post_id: it }
          nil
        end
      end
    end
  end
end
