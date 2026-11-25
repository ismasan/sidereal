# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sidereal/router'

class TestRouter < Sidereal::Router
  get '/' do
    body 'root'
  end

  get '/items' do
    body 'items'
  end

  get '/items/:id' do |id:|
    body "item:#{id}"
  end

  get '/items/:id/comments/:comment_id' do |id:, comment_id:|
    body "item:#{id}:comment:#{comment_id}"
  end

  post '/items' do
    status 201
    body 'created'
  end

  put '/items/:id' do |id:|
    body "updated:#{id}"
  end

  patch '/items/:id' do |id:|
    body "patched:#{id}"
  end

  delete '/items/:id' do |id:|
    body "deleted:#{id}"
  end

  redirect '/old', '/items'

  get '/context' do
    body ["method:#{request.request_method}"]
  end

  callable_handler = ->(req, resp, params) {
    resp.add_header 'Content-Type', 'text/plain'
    resp.body = ["callable:#{params[:id]}:#{req.request_method}"]
  }
  get '/callable/:id', callable_handler

  raw_triplet_handler = ->(req, _resp, params) {
    [202, { 'Content-Type' => 'text/plain' }, ["raw:#{params[:id]}"]]
  }
  get '/raw/:id', raw_triplet_handler
end

class SessionRouter < Sidereal::Router
  session secret: 'a' * 64

  post '/login' do
    session[:user_id] = request.params['user_id']
    body 'logged in'
  end

  get '/profile' do
    user_id = session[:user_id]
    if user_id
      body "user:#{user_id}"
    else
      status 401
      body 'unauthorized'
    end
  end

  post '/logout' do
    session.clear
    body 'logged out'
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
      get '/items/42/comments/7?foo=bar'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('item:42:comment:7')
    end

    it 'URL-decodes captured param values' do
      get '/items/a%20b.%3E'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('item:a b.>')
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
      expect(last_response.headers['Location']).to eq('http://example.org/items')
    end
  end

  describe '#send_file' do
    include_context 'tmp files'

    # Each example routes GET /file to a block that sends a file.
    def app = @app

    def route(&block)
      @app = Class.new(Sidereal::Router) { get('/file', &block) }
    end

    it 'streams the file, with its type and length, and no default text/html' do
      pdf = write('report.pdf', '%PDF-1.4 hello')
      route { send_file pdf }

      status, headers, body = app.call(Rack::MockRequest.env_for('/file'))

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('application/pdf')
      expect(headers['content-length']).to eq('14')
      expect(headers['x-content-type-options']).to eq('nosniff')
      expect(body.to_path).to eq(pdf)
      expect(body.to_enum(:each).to_a.join).to eq('%PDF-1.4 hello')
    end

    it 'answers a byte range with a 206' do
      pdf = write('report.pdf', '%PDF-1.4 hello')
      route { send_file pdf }

      get '/file', {}, 'HTTP_RANGE' => 'bytes=0-3'

      expect(last_response.status).to eq(206)
      expect(last_response.headers['content-range']).to eq('bytes 0-3/14')
      expect(last_response.body).to eq('%PDF')
    end

    it 'answers If-Modified-Since with a 304' do
      pdf = write('report.pdf', '%PDF')
      route { send_file pdf }

      get '/file', {}, 'HTTP_IF_MODIFIED_SINCE' => File.mtime(pdf).httpdate

      expect(last_response.status).to eq(304)
      expect(last_response.body).to be_empty
    end

    it 'is a 404 for a missing file' do
      missing = File.join(tmp_dir, 'nope.pdf')
      route { send_file missing }

      get '/file'

      expect(last_response.status).to eq(404)
    end

    it 'names the file, in ASCII and in UTF-8, inline or as a download' do
      pdf = write('a.pdf', '%PDF')
      route { send_file pdf, filename: 'Café "menu".pdf', disposition: request.params['download'] ? :attachment : :inline }

      get '/file'
      expect(last_response.headers['content-disposition'])
        .to eq(%(inline; filename="Caf_ _menu_.pdf"; filename*=UTF-8''Caf%C3%A9%20%22menu%22.pdf))

      get '/file', download: '1'
      expect(last_response.headers['content-disposition']).to start_with('attachment; filename="Caf_ _menu_.pdf"')
    end

    it 'sends a type and cache-control given, and a download without a name' do
      data = write('blob', 'x')
      route { send_file Pathname(data), type: 'text/plain', cache_control: 'private, max-age=60', disposition: :attachment }

      get '/file'

      expect(last_response.headers['content-type']).to eq('text/plain')
      expect(last_response.headers['cache-control']).to eq('private, max-age=60')
      expect(last_response.headers['content-disposition']).to eq('attachment')
    end

    it "sends a file of an unknown type as application/octet-stream, and doesn't name it unless asked" do
      data = write('blob', 'x')
      route { send_file data }

      get '/file'

      expect(last_response.headers['content-type']).to eq('application/octet-stream')
      expect(last_response.headers).not_to have_key('content-disposition')
    end

    it 'raises for an unknown disposition' do
      data = write('blob', 'x')
      route { send_file data, disposition: :download }

      expect { get '/file' }.to raise_error(ArgumentError, /disposition/)
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

    it 'merges query-string params into router.params with symbol keys' do
      get '/items/42?foo=a&bar=b'
      expect(last_request.env['router.params']).to eq({ id: '42', foo: 'a', bar: 'b' })
    end

    it 'prefers path params over query params on key collision' do
      get '/items/42?id=99'
      expect(last_request.env['router.params']).to eq({ id: '42' })
    end
  end

  describe '#script_name snapshot' do
    it 'captures SCRIPT_NAME at init time' do
      env = Rack::MockRequest.env_for('/items', 'SCRIPT_NAME' => '/myapp')
      router = TestRouter.new(Rack::Request.new(env))
      expect(router.script_name).to eq('/myapp')
    end

    it 'is unaffected when env SCRIPT_NAME is mutated after init (simulates Rack::URLMap restore)' do
      env = Rack::MockRequest.env_for('/items', 'SCRIPT_NAME' => '/myapp')
      router = TestRouter.new(Rack::Request.new(env))
      env['SCRIPT_NAME'] = ''
      expect(router.script_name).to eq('/myapp')
    end

    it 'url() uses the snapshotted prefix after env mutation' do
      env = Rack::MockRequest.env_for('/items', 'SCRIPT_NAME' => '/myapp')
      router = TestRouter.new(Rack::Request.new(env))
      env['SCRIPT_NAME'] = ''
      expect(router.url('/items', false)).to eq('/myapp/items')
    end
  end

  describe 'callable handler' do
    it 'receives request and params' do
      get '/callable/99'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('callable:99:GET')
    end
  end

  describe 'raw Rack triplet handler' do
    it 'returns the triplet as-is' do
      get '/raw/55'
      expect(last_response.status).to eq(202)
      expect(last_response.headers['Content-Type']).to eq('text/plain')
      expect(last_response.body).to eq('raw:55')
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

  describe 'sessions, in a subclass of a router with them' do
    def app
      @app ||= Class.new(SessionRouter)
    end

    it 'has the same sessions as its superclass' do
      post '/login', user_id: '7'
      expect(last_response.headers['set-cookie']).to include('rack.session')

      get '/profile'
      expect(last_response.body).to eq('user:7')
    end
  end

  describe 'sessions with a callable secret' do
    let(:secrets) { ['a' * 64] }

    let(:lazy_router) do
      current = secrets
      Class.new(SessionRouter) do
        session secret: -> { current.last }
      end
    end

    def app
      lazy_router
    end

    it "doesn't read the secret until a request comes in" do
      calls = 0
      Class.new(Sidereal::Router) { session secret: -> { calls += 1 } }

      expect(calls).to eq(0)
    end

    it 'persists session data across requests' do
      post '/login', user_id: '42'
      get '/profile'

      expect(last_response.body).to eq('user:42')
    end

    it 'reads the secret on each request, so a new one drops the old sessions' do
      post '/login', user_id: '42'
      secrets << ('b' * 64)
      get '/profile'

      expect(last_response.status).to eq(401)

      post '/login', user_id: '7'
      get '/profile'
      expect(last_response.body).to eq('user:7')
    end
  end

  describe 'before block' do
    let(:before_router) do
      Class.new(Sidereal::Router) do
        before do
          halt 403, 'forbidden' if request.env['HTTP_X_BLOCK']
        end

        get '/open' do
          body 'welcome'
        end
      end
    end

    def app
      before_router
    end

    it 'runs before route handler' do
      get '/open'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('welcome')
    end

    it 'can halt the request before the handler runs' do
      get '/open', {}, { 'HTTP_X_BLOCK' => '1' }
      expect(last_response.status).to eq(403)
      expect(last_response.body).to eq('forbidden')
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
