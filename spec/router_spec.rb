# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sidereal/router'

class TestRouter < Sidereal::Router
  get '/' do
    [200, { 'Content-Type' => 'text/plain' }, ['root']]
  end

  get '/items' do
    [200, { 'Content-Type' => 'text/plain' }, ['items']]
  end

  get '/items/:id' do |id:|
    [200, { 'Content-Type' => 'text/plain' }, ["item:#{id}"]]
  end

  get '/items/:id/comments/:comment_id' do |id:, comment_id:|
    [200, { 'Content-Type' => 'text/plain' }, ["item:#{id}:comment:#{comment_id}"]]
  end

  post '/items' do
    [201, { 'Content-Type' => 'text/plain' }, ['created']]
  end

  put '/items/:id' do |id:|
    [200, { 'Content-Type' => 'text/plain' }, ["updated:#{id}"]]
  end

  patch '/items/:id' do |id:|
    [200, { 'Content-Type' => 'text/plain' }, ["patched:#{id}"]]
  end

  delete '/items/:id' do |id:|
    [200, { 'Content-Type' => 'text/plain' }, ["deleted:#{id}"]]
  end

  redirect '/old', '/items'

  get '/context' do
    [200, { 'Content-Type' => 'text/plain' }, ["method:#{request.request_method}"]]
  end

  callable_handler = ->(req, params) {
    [200, { 'Content-Type' => 'text/plain' }, ["callable:#{params[:id]}:#{req.request_method}"]]
  }
  get '/callable/:id', callable_handler
end

class SessionRouter < Sidereal::Router
  session secret: 'a' * 64

  post '/login' do
    session[:user_id] = request.params['user_id']
    [200, { 'Content-Type' => 'text/plain' }, ['logged in']]
  end

  get '/profile' do
    user_id = session[:user_id]
    if user_id
      [200, { 'Content-Type' => 'text/plain' }, ["user:#{user_id}"]]
    else
      [401, { 'Content-Type' => 'text/plain' }, ['unauthorized']]
    end
  end

  post '/logout' do
    session.clear
    [200, { 'Content-Type' => 'text/plain' }, ['logged out']]
  end
end

RSpec.describe Sidereal::Router do
  include Rack::Test::Methods

  def app
    TestRouter
  end

  describe 'static routes' do
    it 'GET / returns 200' do
      get '/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('root')
    end

    it 'GET /items returns 200' do
      get '/items'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('items')
    end
  end

  describe 'parameterized routes' do
    it 'extracts a single param' do
      get '/items/42'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('item:42')
    end

    it 'extracts multiple params' do
      get '/items/42/comments/7'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('item:42:comment:7')
    end
  end

  describe 'HTTP methods' do
    it 'POST' do
      post '/items'
      expect(last_response.status).to eq(201)
      expect(last_response.body).to eq('created')
    end

    it 'PUT' do
      put '/items/42'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('updated:42')
    end

    it 'PATCH' do
      patch '/items/42'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('patched:42')
    end

    it 'DELETE' do
      delete '/items/42'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('deleted:42')
    end
  end

  describe 'trailing slashes' do
    it 'matches static route with trailing slash' do
      get '/items/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('items')
    end

    it 'matches parameterized route with trailing slash' do
      get '/items/42/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('item:42')
    end

    it 'matches nested parameterized route with trailing slash' do
      get '/items/42/comments/7/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('item:42:comment:7')
    end

    it 'matches root route with empty path_info (mounted sub-app)' do
      get ''
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('root')
    end
  end

  describe 'redirects' do
    it 'returns 301 with Location header' do
      get '/old'
      expect(last_response.status).to eq(301)
      expect(last_response.headers['Location']).to eq('/items')
    end
  end

  describe '404' do
    it 'returns 404 for unmatched path' do
      get '/nope'
      expect(last_response.status).to eq(404)
    end

    it 'returns 404 for wrong HTTP method' do
      delete '/items'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'request context' do
    it 'exposes the request object to handlers' do
      get '/context'
      expect(last_response.body).to eq('method:GET')
    end

    it 'sets router.params in the env' do
      get '/items/42'
      expect(last_request.env['router.params']).to eq({ id: '42' })
    end
  end

  describe 'callable handler' do
    it 'receives request and params' do
      get '/callable/99'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('callable:99:GET')
    end
  end

  describe 'sessions', app: :session do
    def app
      SessionRouter
    end

    it 'returns 401 when not logged in' do
      get '/profile'
      expect(last_response.status).to eq(401)
    end

    it 'persists session data across requests' do
      post '/login', user_id: '42'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('logged in')

      get '/profile'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('user:42')
    end

    it 'clears session on logout' do
      post '/login', user_id: '42'
      get '/profile'
      expect(last_response.body).to eq('user:42')

      post '/logout'
      expect(last_response.body).to eq('logged out')

      get '/profile'
      expect(last_response.status).to eq(401)
    end

    it 'sets a signed cookie' do
      post '/login', user_id: '1'
      cookie = last_response.headers['set-cookie']
      expect(cookie).to include('rack.session')
    end
  end

  describe '#session without configuration' do
    it 'raises when sessions are not enabled' do
      # TestRouter has no session configured
      env = Rack::MockRequest.env_for('/')
      req = Rack::Request.new(env)
      router = TestRouter.new(req)
      expect { router.session }.to raise_error(RuntimeError, /Sessions not configured/)
    end
  end
end
