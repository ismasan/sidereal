# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'

RSpec.describe Sidereal::ShowExceptions do
  include Rack::Test::Methods

  ShowExceptionsTestCmd = Sidereal::Message.define('show_exceptions_test.boom') do
    attribute :title, String
  end

  class ShowExceptionsTestError < StandardError; end

  let(:app) do
    Class.new(Sidereal::App) do
      handle ShowExceptionsTestCmd do |_cmd|
        browser.stream(heartbeat: false) { |_sse| raise ShowExceptionsTestError, 'boom while streaming' }
      end

      get '/boom' do
        raise ShowExceptionsTestError, 'boom <here>'
      end
    end
  end

  around do |example|
    Sidereal.environment = 'development'
    example.run
  ensure
    Sidereal.environment = nil
  end

  it 'answers a page request with a 500 report of the exception' do
    get '/boom'

    expect(last_response.status).to eq(500)
    expect(last_response.headers['content-type']).to eq('text/html; charset=utf-8')
    html = last_response.body
    expect(html).to start_with('<!doctype html>')
    expect(html).to include('<h1>ShowExceptionsTestError</h1>', 'boom &lt;here&gt;')
    expect(html).to include("spec/show_exceptions_spec.rb:#{__LINE__ - 20}")
    expect(html).to include('class="is-current"')
    expect(html).to include('/boom')
  end

  it 'answers a Datastar request with an overlay to append to the page' do
    get '/boom', {}, { 'HTTP_DATASTAR_REQUEST' => 'true' }

    expect(last_response.status).to eq(200)
    expect(last_response.headers).to include('datastar-selector' => 'body', 'datastar-mode' => 'append')
    expect(last_response.body).not_to include('<!doctype html>')
    expect(last_response.body).to include('sidereal-exception--overlay', 'ShowExceptionsTestError')
  end

  # The stream runs as its body is read, and the exception carries on to the
  # streamer's on_error, which prints it.
  def streamed_body
    post '/commands', command: { type: 'show_exceptions_test.boom', payload: { title: 'x' } }
    body = nil
    expect { body = last_response.body }.to output(/boom while streaming/).to_stdout
    body
  end

  it 'appends an overlay to a stream that raised' do
    body = streamed_body

    expect(last_response.status).to eq(200)
    expect(body).to include('event: datastar-patch-elements', 'data: selector body', 'data: mode append')
    expect(body).to include('sidereal-exception--overlay', 'boom while streaming')
  end

  it 'reports nothing for an app defined outside development' do
    Sidereal.environment = 'production'

    expect(app.show_exceptions?).to be(false)
    expect(app.streamer_class).to equal(Datastar::Dispatcher)
    expect { get '/boom' }.to raise_error(ShowExceptionsTestError)
    expect(streamed_body).not_to include('sidereal-exception')
  end

  it 'decides when the app is defined, not per request' do
    expect(app.show_exceptions?).to be(true)
    expect(app.streamer_class).to equal(Sidereal::App::ExceptionStreamer)
    Sidereal.environment = 'production'

    get '/boom'
    expect(last_response.status).to eq(500)
    expect(streamed_body).to include('sidereal-exception--overlay')
  end
end
