# frozen_string_literal: true

RSpec.describe CrossPost do
  let(:account_id) { '7c2e1a90-3b4d-4e5f-8a6b-1c2d3e4f5a60' }
  let(:post_id) { '8d3f2b01-4c5e-4f60-9b7c-2d3e4f5a6b70' }
  let(:connection_id) { '9e4a3c12-5d6f-4a71-8c8d-3e4f5a6b7c80' }

  def cmd(klass, **payload) = klass.new(payload: { account_id:, **payload })

  def instance(machine, keys, history) = machine.new(keys).tap { it.evolve(history) }

  it 'validates every machine in the tree' do
    expect(described_class.machines.map(&:to_h)).to all(include(:states))
  end

  describe CrossPost::Account do
    def history(*commands, given: []) = decided(CrossPost::Account, { account_id: }, *commands, given:)
    def account(history) = instance(CrossPost::Account, { account_id: }, history)
    def token(history) = history.grep(CrossPost::Account::VerificationLinkSent).last.payload.token

    let(:signed_up) { history(cmd(CrossPost::Account::SignUp, email: 'ada@example.com', password: 'secret')) }
    let(:active) { history(cmd(CrossPost::Account::Verifying::VerifyEmail, token: token(signed_up)), given: signed_up) }

    it 'waits for the email link after signing up, taking no logins or posts' do
      account = account(signed_up)

      expect(account.machine.value).to eq(CrossPost::Account::Verifying::State => CrossPost::Account::Verifying::AwaitingClick)
      expect(account.handles_command?(cmd(CrossPost::Account::Active::LogIn, password: 'secret'))).to be(false)
      expect(account.handles_command?(cmd(CrossPost::Account::DraftPost))).to be(false)
    end

    it 'stays unverified on a wrong token, and activates on the right one' do
      wrong = history(cmd(CrossPost::Account::Verifying::VerifyEmail, token: 'nope'), given: signed_up)

      expect(account(wrong).machine.value).to eq(CrossPost::Account::Verifying::State => CrossPost::Account::Verifying::AwaitingClick)
      expect(account(active).machine.value).to eq(CrossPost::Account::Active::State => CrossPost::Account::Active::Open)
    end

    it 'refuses a click on an expired link' do
      expired = history(cmd(CrossPost::Account::Verifying::ExpireLink), given: signed_up)
      verify = cmd(CrossPost::Account::Verifying::VerifyEmail, token: token(signed_up))

      expect(account(expired).handles_command?(verify)).to be(false)
    end

    it 'starts a session on login, and locks after five failures' do
      logged_in = history(cmd(CrossPost::Account::Active::LogIn, session_id: post_id, password: 'secret'), given: active)
      expect(logged_in.grep(CrossPost::Session::Started).size).to eq(1)

      bad = cmd(CrossPost::Account::Active::LogIn, password: 'wrong')
      locked = history(*Array.new(5) { bad }, given: active)

      expect(account(locked).machine.value).to eq(CrossPost::Account::Active::State => CrossPost::Account::Active::Locked)
      expect(account(locked).handles_command?(bad)).to be(false)
    end

    it 'connects a service once' do
      connect = cmd(CrossPost::Account::ConnectService, connection_id:, service: 'x')
      twice = history(connect, cmd(CrossPost::Account::ConnectService, service: 'x'), given: active)

      expect(twice.grep(CrossPost::Connections::X::Started).size).to eq(1)
    end
  end

  describe CrossPost::Connections::X do
    let(:keys) { { account_id:, connection_id: } }

    it 'connects through its OAuth handshake' do
      started = CrossPost::Connections::X::Started.new(payload: { **keys, input: {}, trigger: 'start', source: 'initial', target: 'authorizing.redirecting', exited: [], entered: %w[authorizing authorizing.redirecting] })
      handshake = CrossPost::Connections::X::Authorizing
      connected = decided(
        CrossPost::Connections::X, keys,
        handshake::ReceiveCode.new(payload: { **keys, code: 'c', state: 's' }),
        handshake::CompleteExchange.new(payload: { **keys, handle: '@ada', scopes: %w[tweet.write] }),
        given: [started]
      )

      expect(instance(CrossPost::Connections::X, keys, connected).machine.value).to eq(CrossPost::Connections::X::Connected)
    end
  end

  describe CrossPost::Post do
    let(:keys) { { account_id:, post_id: } }
    let(:targets) { CrossPost::Post::Targets }

    def post_cmd(klass, **payload) = klass.new(payload: { **keys, **payload })
    def post(history) = instance(CrossPost::Post, keys, history)

    # A draft started with X connected, its regions placed by Sync.
    let(:draft) do
      started = CrossPost::Post::Started.new(payload: {
        **keys, input: { services: ['x'] }, trigger: 'start', source: 'initial', target: 'drafting',
        exited: [], entered: ['drafting']
      })
      decided(CrossPost::Post, keys, post_cmd(targets::Sync), given: [started])
    end

    it 'can only select connected services' do
      expect(post(draft).machine.in?(targets::X::Available)).to be(true)
      expect(post(draft).handles_command?(post_cmd(targets::Bluesky::Select))).to be(false)
    end

    it 'submits once every selected service is valid' do
      too_long = decided(CrossPost::Post, keys, post_cmd(CrossPost::Post::EditText, text: 'a' * 300), post_cmd(targets::X::Select), given: draft)
      expect(post(too_long).machine.in?(targets::X::Invalid)).to be(true)

      refused = decided(CrossPost::Post, keys, post_cmd(CrossPost::Post::Submit), given: too_long)
      expect(post(refused).machine.in?(CrossPost::Post::Drafting)).to be(true)

      fixed = decided(CrossPost::Post, keys, post_cmd(CrossPost::Post::EditText, text: 'hello'), post_cmd(targets::Validate), post_cmd(CrossPost::Post::Submit), given: too_long)
      expect(post(fixed).machine.in?(CrossPost::Post::Publishing)).to be(true)
    end
  end
end
