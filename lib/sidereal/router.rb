# frozen_string_literal: true

require 'rack'
require 'rack/session/cookie'
require_relative 'request_helpers'

module Sidereal
  # A minimal Rack-compatible router with a Sinatra-style DSL and
  # trie-based dispatch.
  #
  # Routes are stored in a trie (prefix tree) keyed by path segment,
  # giving O(path segments) lookup regardless of the total number of
  # registered routes. Static segments are matched by exact hash lookup;
  # dynamic segments (+:param+) act as wildcard keys that capture the
  # corresponding path value.
  #
  # Subclass and define routes with {.get}, {.post}, {.put}, {.patch}, {.delete},
  # or {.redirect}. Route blocks are evaluated in the context of a router instance,
  # so they have access to {#request} and any instance methods defined on the subclass.
  #
  # Named parameters in paths (e.g. +:id+) are extracted and passed to the block
  # as keyword arguments. Trailing slashes are handled automatically — +/items+ and
  # +/items/+ match the same route. The root path (+/+) also matches an empty
  # +path_info+ for mounted sub-apps.
  #
  # Unmatched requests return +404+.
  #
  # @example Basic subclass with routes
  #   class MyApp < Sidereal::Router
  #     get '/' do
  #       [200, { 'Content-Type' => 'text/plain' }, ['hello']]
  #     end
  #
  #     get '/items/:id' do |id:|
  #       [200, { 'Content-Type' => 'text/plain' }, ["item #{id}"]]
  #     end
  #
  #     post '/items' do
  #       [201, { 'Content-Type' => 'text/plain' }, ['created']]
  #     end
  #
  #     redirect '/legacy', '/items'
  #   end
  #
  # @example Callable handler objects
  #   # Any object (or lambda) that responds to #call(request, params)
  #   # can be passed as a handler instead of a block. Useful for
  #   # extracting route logic into standalone, testable objects.
  #
  #   class ShowItem
  #     def call(request, params)
  #       id = params[:id]
  #       [200, { 'Content-Type' => 'text/plain' }, ["item #{id}"]]
  #     end
  #   end
  #
  #   class MyApp < Sidereal::Router
  #     get '/items/:id', ShowItem.new
  #
  #     # Lambdas work too
  #     get '/health', ->(req, params) { [200, {}, ['ok']] }
  #   end
  #
  # @example Mounting as a Rack app
  #   # config.ru
  #   run MyApp
  #
  # @example Using with Rack::Builder
  #   app = Rack::Builder.new do
  #     use Rack::Static, urls: ['/assets'], root: 'public'
  #     run MyApp
  #   end
  class Router
    include RequestHelpers

    Iterable = Plumb::Types::Interface[:each]
    Callable = Plumb::Types::Interface[:call]

    GET = 'GET'
    POST = 'POST'
    DELETE = 'DELETE'
    PATCH = 'PATCH'
    PUT = 'PUT'

    # Split a path into segments, stripping leading/trailing slashes.
    #
    # @param path [String] URL path (e.g. +"/items/42/"+)
    # @return [Array<String>] path segments (e.g. +["items", "42"]+)
    def self.split_path(path)
      path.delete_prefix('/').delete_suffix('/').split('/')
    end

    # @api private
    # Matches a colon-prefixed segment and captures the name.
    PARAM_EXP = /\A:(.+)/

    # A dynamic path segment descriptor produced by {.compile}.
    # Holds the parameter name as a Symbol (e.g. +Param[:id]+).
    Param = Data.define(:name)

    # A node in the route trie.
    #
    # Static segments are stored as hash keys for O(1) lookup.
    # A single optional dynamic segment (+:param+) is stored in
    # {#param_name} / {#param_child} for direct access without
    # scanning keys.
    #
    # The empty-string key (+""+ ) at a leaf holds the handler.
    class Node < Hash
      # @return [Symbol, nil] the parameter name, if this node has a dynamic child
      attr_accessor :param_name

      # @return [Node, nil] the child node for the dynamic segment
      attr_accessor :param_child
    end

    class << self
      # Returns the route tries, keyed by HTTP method.
      #
      # Each value is a {Node} (trie root) where string keys are static
      # path segments, dynamic segments are stored via {Node#param_name}
      # / {Node#param_child}, and the empty-string key (+""+ ) at a
      # leaf holds the handler.
      #
      # @return [Hash{String => Node}]
      def routes
        @routes ||= {
          GET => Node.new,
          POST => Node.new,
          DELETE => Node.new,
          PATCH => Node.new,
          PUT => Node.new
        }
      end

      def inherited(subclass)
        routes.each do |k, v|
          subclass.routes[k] = v.dup
        end
      end

      def before(&block)
        define_method(:before_route, &block)
        private :before_route
      end

      # Register a GET route.
      #
      # @param path [String] URL pattern, may include named params (e.g. +/items/:id+)
      # @param handler [#call, nil] callable handler; if omitted, a block is expected
      # @yield Block evaluated in the router instance context when the route matches
      # @yieldparam kwargs [Symbol => String] named parameters extracted from the path
      # @return [self]
      #
      # @example Static path
      #   get '/health' do
      #     [200, {}, ['ok']]
      #   end
      #
      # @example With named parameters
      #   get '/users/:user_id/posts/:id' do |user_id:, id:|
      #     [200, {}, ["user=#{user_id} post=#{id}"]]
      #   end
      def get(path, handler = nil, &h)
        add GET, path, handler, &h
      end

      # Register a POST route.
      #
      # @param path [String] URL pattern
      # @param handler [#call, nil] callable handler
      # @yield (see .get)
      # @yieldparam kwargs (see .get)
      # @return [self]
      def post(path, handler = nil, &h)
        add POST, path, handler, &h
      end

      # Register a PUT route.
      #
      # @param path [String] URL pattern
      # @param handler [#call, nil] callable handler
      # @yield (see .get)
      # @yieldparam kwargs (see .get)
      # @return [self]
      def put(path, handler = nil, &h)
        add PUT, path, handler, &h
      end

      # Register a PATCH route.
      #
      # @param path [String] URL pattern
      # @param handler [#call, nil] callable handler
      # @yield (see .get)
      # @yieldparam kwargs (see .get)
      # @return [self]
      def patch(path, handler = nil, &h)
        add PATCH, path, handler, &h
      end

      # Register a DELETE route.
      #
      # @param path [String] URL pattern
      # @param handler [#call, nil] callable handler
      # @yield (see .get)
      # @yieldparam kwargs (see .get)
      # @return [self]
      def delete(path, handler = nil, &h)
        add DELETE, path, handler, &h
      end

      # Register a GET redirect from one path to another.
      #
      # Returns a +301 Moved Permanently+ with the +Location+ header set.
      #
      # @param from [String] source URL pattern
      # @param to [String] target URL
      # @return [self]
      #
      # @example
      #   redirect '/old-path', '/new-path'
      def redirect(from_path, to_path)
        get from_path do
          redirect to(to_path), status: 301
        end
      end

      # Configure signed cookie sessions for this router.
      #
      # Wraps the router in +Rack::Session::Cookie+ middleware with HMAC signing.
      # Once enabled, route handlers can access the session via {#session}.
      #
      # @param secret [String] HMAC signing secret (required, must be >= 64 bytes
      #   for security; +Rack::Session::Cookie+ enforces a 16-byte minimum)
      # @param opts [Hash] additional options forwarded to +Rack::Session::Cookie+
      # @option opts [String] :key cookie name (default: +"rack.session"+)
      # @option opts [String] :path cookie path (default: +"/"+)
      # @option opts [Boolean] :httponly (default: +true+)
      # @option opts [Symbol] :same_site +:lax+, +:strict+, or +:none+ (default: +:lax+)
      # @option opts [Integer] :expire_after seconds until cookie expires
      # @return [void]
      #
      # @example
      #   class MyApp < Sidereal::Router
      #     session secret: ENV.fetch('SESSION_SECRET')
      #
      #     get '/login' do
      #       session[:user_id] = 42
      #       [200, {}, ['logged in']]
      #     end
      #
      #     get '/profile' do
      #       [200, {}, ["user: #{session[:user_id]}"]]
      #     end
      #   end
      def session(secret:, **opts)
        session_options = { secret: }.merge(opts)
        self.app = Rack::Session::Cookie.new(app, **session_options)
        self
      end

      # Set the Rack app used by {.call}.
      #
      # Typically set by {.session} to wrap the router in middleware.
      #
      # @param a [#call] a Rack-compatible app
      # @api private
      def app=(a)
        @app = a
      end

      # The Rack app dispatched by {.call}.
      #
      # Defaults to {.route}. When middleware (e.g. sessions) is added,
      # the middleware wraps this and becomes the new +app+.
      #
      # @return [#call]
      # @api private
      def app
        @app ||= method(:route)
      end

      # Register a route.
      #
      # @param verb [String] HTTP method ('POST', 'GET', etc)
      # @param path [String] URL pattern
      # @param handler [#call, nil] callable handler
      # @yield (see .get)
      # @yieldparam kwargs (see .get)
      # @return [self]
      def add(verb, path, handler = nil, &h)
        handler ||= h
        segments = compile(path)
        merge_route!(routes[verb], segments, handler)
        self
      end

      # Rack-compatible call interface.
      #
      # Delegates to {.app}, which is either {.route} directly or
      # a middleware chain (e.g. +Rack::Session::Cookie+) wrapping it.
      #
      # @param env [Hash] Rack environment
      # @return [Array(Integer, Hash, Array)] Rack response triplet
      def call(env)
        app.call(env)
      end

      # Inner Rack endpoint that performs route matching.
      #
      # Wraps the env in a +Rack::Request+ and delegates to {#call}.
      # This is the default {.app} and the target that middleware wraps.
      #
      # @param env [Hash] Rack environment
      # @return [Array(Integer, Hash, Array)] Rack response triplet
      # @api private
      def route(env)
        req = Rack::Request.new(env)
        new(req).call
      end

      private

      # Compile a path pattern into an array of segment descriptors.
      #
      # Strips leading/trailing slashes and splits on +/+. Each segment
      # is either a plain String (static) or a {Param} (dynamic).
      # An empty string is appended as the leaf sentinel.
      #
      # @param path [String] route pattern (e.g. +/items/:id+)
      # @return [Array<String, Param>] segment descriptors ending with +""+
      private def compile(path)
        split_path(path).map do |segment|
          m = PARAM_EXP.match(segment)
          m ? Param.new(m[1].to_sym) : segment
        end << ''
      end

      # Insert a route into the trie.
      #
      # Static segments become hash keys on {Node} for O(1) lookup.
      # Dynamic segments ({Param}) are stored via {Node#param_name} and
      # {Node#param_child} for direct access. The empty-string leaf
      # sentinel (+""+ ) stores the handler.
      #
      # @example Resulting trie for +get '/items/:id'+
      #   Node{ "items" => Node{ param_name: :id, param_child: Node{ "" => handler } } }
      private def merge_route!(node, segments, handler)
        segments.each do |seg|
          case seg
          when Param
            node.param_name = seg.name
            node.param_child ||= Node.new
            node = node.param_child
          when ''
            node[seg] = handler
          else
            node[seg] ||= Node.new
            node = node[seg]
          end
        end
      end
    end

    BLANK_BODY = [].freeze
    DEFAULT_HEADERS = {
      'Content-Type' => 'text/html'
    }.freeze

    # @return [Rack::Request] the current request
    attr_reader :request, :response

    # @param request [Rack::Request]
    def initialize(request)
      @request = request
      @response = Rack::Response.new(BLANK_BODY, 200, DEFAULT_HEADERS.dup)
    end

    private def before_route
    end

    # Returns the session hash for the current request.
    #
    # Only available when sessions are enabled via {.session} on the
    # router subclass. Raises if sessions are not configured.
    #
    # @return [Rack::Session::Abstract::SessionHash] session data
    # @raise [RuntimeError] if sessions are not enabled
    #
    # @example Reading and writing session data
    #   post '/login' do
    #     session[:user_id] = request.params['user_id']
    #     [200, {}, ['ok']]
    #   end
    #
    #   get '/whoami' do
    #     [200, {}, ["user: #{session[:user_id]}"]]
    #   end
    def session
      request.env['rack.session'] || raise('Sessions not configured. Use `session secret: "..."` in your Router subclass.')
    end

    # Dispatch the request to a matching route handler.
    #
    # Walks the trie for the request's HTTP method, matching each path
    # segment by exact hash lookup (static) or {Node#param_child}
    # fallback (dynamic). Returns +404+ if no route matches.
    #
    # Matched path parameters are stored in
    # +request.env['router.params']+ as a symbol-keyed hash.
    #
    # When the handler is a block, it is evaluated via +instance_exec+
    # in the router instance context with named params as keyword arguments.
    # When the handler is a lambda or any other callable, it receives the
    # +Rack::Request+ and extracted params hash via +#call+.
    #
    # @return [Array(Integer, Hash, Array)] Rack response triplet
    def call
      node = self.class.routes[request.request_method]
      return not_found unless node

      segments = self.class.split_path(request.path_info)
      params = nil

      segments.each do |segment|
        child = node[segment]
        unless child
          return not_found unless node.param_child

          child = node.param_child
          (params ||= {})[node.param_name] = segment
        end
        node = child
        return not_found unless node.is_a?(Node)
      end

      handler = node['']
      return not_found unless handler

      resp = catch :halt do
        params ||= EMPTY_PARAMS
        request.env['router.params'] = params
        before_route

        ret = if handler.is_a?(Proc) && !handler.lambda?
          instance_exec(**params, &handler)
        else
          handler.call(request, response, params)
        end
        response
      end
      resp.finish
    end

    NOT_FOUND = [404, {'Content-Type' => 'text/html'}.freeze, ['Resource not found'].freeze].freeze
    EMPTY_PARAMS = {}.freeze

    private_constant :NOT_FOUND, :EMPTY_PARAMS

    private

    def not_found
      NOT_FOUND
    end

    # halt 422
    # halt 200, 'hello'
    def halt(*args)
      case args
      in [Integer => st]
        status st
      in [Integer => st, Hash => h]
        status st
        headers h
      in [Integer => st, Object => b]
        status st
        body b
      in [Integer => st, Hash => h, Object => b]
        status st
        headers h
        body b
      end

      throw :halt, response
    end

    def component(cmp, status: 200)
      self.status status
      body cmp.call(context: self)
    end

    def status(st)
      response.status = Rack::Utils.status_code(st)
    end

    def body(b)
      bd = case b
           when String
             [b]
           when Iterable, Callable
             b
           else
             raise ArgumentError, "response body must be a String, Array, #call() or #each interface, but got #{b.inspect}"
           end

      response.body = bd
    end

    def headers(h)
      h.each do |k, v|
        response.add_header k, v
      end
    end

    def redirect(location, status: 301)
      halt status, 'Location' => location
    end
  end
end
