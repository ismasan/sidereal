# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'async'

HandleTestCmd = Sidereal::Message.define('app_test.do_thing') do
  attribute :title, Sidereal::Types::String.present
end

HandleTestOtherCmd = Sidereal::Message.define('app_test.do_other') do
  attribute :name, Sidereal::Types::String.present
end

RSpec.describe 'Sidereal::App.commander' do
  it 'auto-registers no-op handlers for system notifications' do
    app = Class.new(Sidereal::App)
    app.const_set(:Name, 'AutoRegisterTestApp') # for naming, optional

    expect(app.commander.command_registry).to include(
      Sidereal::System::NotifyRetry.type => Sidereal::System::NotifyRetry,
      Sidereal::System::NotifyFailure.type => Sidereal::System::NotifyFailure
    )
  end

  it 'allows overriding the no-op NotifyFailure handler' do
    captured = []
    app = Class.new(Sidereal::App) do
      command(Sidereal::System::NotifyFailure) { |cmd| captured << cmd }
    end

    cmd = Sidereal::System::NotifyFailure.new(
      payload: {
        command_type: 'x',
        command_id: SecureRandom.uuid,
        attempt: 1,
        error_class: 'RuntimeError',
        error_message: 'oops',
        backtrace: []
      }
    )
    app.commander.handle(cmd, pubsub: Sidereal::PubSub::Memory.new)

    expect(captured).to eq([cmd])
  end
end

RSpec.describe 'Sidereal::App.handle' do
  include Rack::Test::Methods

  let(:store) { Sidereal::Store::Memory.new }

  before do
    allow(Sidereal).to receive(:store).and_return(store)
  end

  describe 'with a local handler' do
    let(:handled) { [] }

    let(:test_app) do
      captured = handled
      Class.new(Sidereal::App) do
        session secret: 'a' * 64

        command HandleTestCmd
        command HandleTestOtherCmd

        handle HandleTestOtherCmd

        handle HandleTestCmd do |cmd|
          captured << cmd
          dispatch(HandleTestOtherCmd, name: 'from handle')
          status 200
        end
      end
    end

    def app
      test_app
    end

    it 'routes the command to the handle block instead of the store' do
      post '/commands', command: { type: 'app_test.do_thing', payload: { title: 'hello' } }

      expect(last_response.status).to eq(200)
      expect(handled.size).to eq(1)
      expect(handled.first).to be_a(HandleTestCmd)
      expect(handled.first.payload.title).to eq('hello')
    end

    it 'can manually append a different command to the store' do
      post '/commands', command: { type: 'app_test.do_thing', payload: { title: 'hello' } }

      expect(last_response.status).to eq(200)
      expect(handled.size).to eq(1)

      claimed = claim_one(store)
      expect(claimed).to be_a(HandleTestOtherCmd)
      expect(claimed.payload.name).to eq('from handle')
      expect(claimed.causation_id).to eq(handled.first.id)
      expect(claimed.correlation_id).to eq(handled.first.correlation_id)
    end

    it 'uses the default handler (dispatch to store + 200) when handle is called without a block' do
      post '/commands', command: { type: 'app_test.do_other', payload: { name: 'bob' } }

      expect(last_response.status).to eq(200)
      expect(handled).to be_empty

      claimed = claim_one(store)
      expect(claimed).to be_a(HandleTestOtherCmd)
      expect(claimed.payload.name).to eq('bob')
    end

  end

  describe '#dispatch outside a handle block' do
    let(:test_app) do
      Class.new(Sidereal::App) do
        session secret: 'a' * 64
        command HandleTestOtherCmd

        post '/enqueue' do
          dispatch(HandleTestOtherCmd, name: 'from-bare-route')
          status 200
        end
      end
    end

    def app
      test_app
    end

    it 'enqueues the command without correlating to any prior message' do
      post '/enqueue'

      expect(last_response.status).to eq(200)
      claimed = claim_one(store)
      expect(claimed).to be_a(HandleTestOtherCmd)
      expect(claimed.payload.name).to eq('from-bare-route')
      # No prior message — causation/correlation default to the message's own id
      expect(claimed.causation_id).to eq(claimed.id)
      expect(claimed.correlation_id).to eq(claimed.id)
    end
  end

  describe '.channel_name macro' do
    it 'defines a static channel name on the App\'s commander' do
      app = Class.new(Sidereal::App) do
        session secret: 'a' * 64
        channel_name 'custom'
        command HandleTestCmd
      end

      msg = HandleTestCmd.new(payload: { title: 'x' })
      expect(app.commander.channel_name(msg)).to eq('custom')
    end

    it 'defines a dynamic channel name from a block' do
      app = Class.new(Sidereal::App) do
        session secret: 'a' * 64
        channel_name { |msg| "items.#{msg.payload.title}" }
        command HandleTestCmd
      end

      msg = HandleTestCmd.new(payload: { title: '42' })
      expect(app.commander.channel_name(msg)).to eq('items.42')
    end
  end

  describe 'handler streaming SSE updates' do
    let(:test_app) do
      Class.new(Sidereal::App) do
        session secret: 'a' * 64

        command HandleTestCmd

        handle HandleTestCmd do |cmd|
          browser.patch_elements '<div id="result">updated</div>'
        end
      end
    end

    def app
      test_app
    end

    it 'streams DOM patches via browser.patch_elements' do
      post '/commands',
        { command: { type: 'app_test.do_thing', payload: { title: 'hello' } } },
        { 'HTTP_ACCEPT' => 'text/event-stream' }

      expect(last_response.status).to eq(200)
      expect(last_response.headers['content-type']).to include('text/event-stream')
      expect(last_response.body).to include('event: datastar-patch-elements')
      expect(last_response.body).to include('<div id="result">updated</div>')
    end

    it 'emits SSE even for a non-SSE request (browser works unconditionally)' do
      post '/commands', command: { type: 'app_test.do_thing', payload: { title: 'hello' } }

      expect(last_response.status).to eq(200)
      expect(last_response.headers['content-type']).to include('text/event-stream')
      expect(last_response.body).to include('<div id="result">updated</div>')
    end
  end

  describe 'updates channel selection' do
    let(:subscribed_channels) { [] }
    let(:fake_pubsub) do
      channels = subscribed_channels
      Class.new do
        define_method(:subscribe) do |channel_name|
          channels << channel_name
          Class.new do
            def stop
            end
          end.new
        end
      end.new
    end

    let(:test_app) do
      Class.new(Sidereal::App)
    end

    def app
      test_app
    end

    before do
      allow(Sidereal).to receive(:pubsub).and_return(fake_pubsub)
    end

    it 'uses the path parameter to choose the updates channel' do
      get '/updates/items.42'

      expect(subscribed_channels).to eq(['items.42'])
    end
  end

  describe 'handle with multiple command classes' do
    let(:test_app) do
      Class.new(Sidereal::App) do
        session secret: 'a' * 64

        command HandleTestCmd
        command HandleTestOtherCmd

        handle HandleTestCmd, HandleTestOtherCmd
      end
    end

    def app
      test_app
    end

    it 'registers all listed commands with the default handler' do
      post '/commands', command: { type: 'app_test.do_thing', payload: { title: 'hello' } }
      expect(last_response.status).to eq(200)

      post '/commands', command: { type: 'app_test.do_other', payload: { name: 'bob' } }
      expect(last_response.status).to eq(200)

      claimed = claim_messages(store, 2)
      expect(claimed.map(&:class)).to eq([HandleTestCmd, HandleTestOtherCmd])
    end
  end

  describe 'without any local handlers' do
    let(:test_app) do
      Class.new(Sidereal::App) do
        session secret: 'a' * 64
        command HandleTestCmd
      end
    end

    def app
      test_app
    end

    it 'returns 404 for commands that were only registered with .command (not .handle)' do
      post '/commands', command: { type: 'app_test.do_thing', payload: { title: 'hello' } }

      expect(last_response.status).to eq(404)
    end

    it 'returns 404 for unknown command types' do
      post '/commands', command: { type: 'app_test.unknown', payload: {} }

      expect(last_response.status).to eq(404)
    end
  end
end
