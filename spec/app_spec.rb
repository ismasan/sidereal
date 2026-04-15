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

      claimed = nil
      Sync do
        store.claim_next { |m| claimed = m }
      end
      expect(claimed).to be_a(HandleTestOtherCmd)
      expect(claimed.payload.name).to eq('from handle')
      expect(claimed.causation_id).to eq(handled.first.id)
      expect(claimed.correlation_id).to eq(handled.first.correlation_id)
    end

    it 'uses the default handler (dispatch to store + 200) when handle is called without a block' do
      post '/commands', command: { type: 'app_test.do_other', payload: { name: 'bob' } }

      expect(last_response.status).to eq(200)
      expect(handled).to be_empty

      claimed = nil
      Sync do
        store.claim_next { |m| claimed = m }
      end
      expect(claimed).to be_a(HandleTestOtherCmd)
      expect(claimed.payload.name).to eq('bob')
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

      claimed = []
      Sync do
        2.times { store.claim_next { |m| claimed << m } }
      end
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
