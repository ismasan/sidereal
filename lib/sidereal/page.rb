# frozen_string_literal: true

require 'set'
require 'openssl'
require 'async/queue'
require_relative 'components/base_component'
require_relative 'components/system_notify'

module Sidereal
  class Page < Components::BaseComponent
    METHOD_PREFIX = '__on_'

    # Fiber-local slot holding the page class being rendered, so a command
    # form anywhere in the component tree can register itself on that page.
    # +Thread.current[]+ is fiber-local, which is what makes this safe under
    # Async: each render runs to completion inside one fiber, and Phlex tracks
    # its own current component the same way.
    RENDERING_KEY = :__sidereal_rendering_page__

    # Where pages' live updates streams are mounted, each at
    # +/_updates/<token>+. See {.stream_token}.
    UPDATES_PATH = '/_updates'

    # The channel {#channel_names} subscribes a page to unless it says otherwise.
    DEFAULT_CHANNEL = Channels::DEFAULT_CHANNEL

    # The +purpose+ stream tokens are signed for. See {Signer#generate}.
    STREAM_PURPOSE = 'sidereal.page_stream'

    # A verified stream token: the page to stream, its decoded params, and
    # the channel patterns to subscribe to: the page's {#channel_names}, and
    # its session's {.session_channel}. See {.resolve_stream}.
    Stream = Data.define(:page_class, :params, :channels)

    # What {.stream_token} signs. A token whose data doesn't match it
    # doesn't resolve.
    STREAM_DATA = Types::Hash[
      'page' => Types::String,
      'params' => Types::Hash,
      'channels' => Types::Array[Types::ChannelPattern].present,
      'session' => Types::String.nullable
    ]

    # Every page stream in a session also subscribes to that session's
    # channel, +sidereal.sessions.<session digest>+, which nothing but
    # Sidereal publishes to. It carries what's meant for one user only, such
    # as the notifications for a command that failed. See {.session_channel}.
    SESSION_CHANNEL_PREFIX = 'sidereal.sessions'

    # The metadata key {App} stamps a command sent from a browser with: its
    # session's {.session_digest}, which names the session without giving
    # its id away. Messages correlated from the command carry it on, so
    # anything they cause can find the session's channel, with
    # {.session_channel_for}, or tell which session it came from.
    SESSION_DIGEST_KEY = :session_digest

    # The session key {.stream_token} writes to when a session has no id yet,
    # since Rack only gives a session an id once something is stored in it.
    SESSION_KEY = 'sidereal.session'

    # Prefixed to the session id before digesting it into a stream token, so
    # the digest doesn't coincide with the key a server-side session store
    # keeps the session under.
    SESSION_DIGEST_PREFIX = "sidereal.session\0"

    # Reaction run for a message whose class has no handler of its own but
    # whose +correlation_type+ the page reacts to: reload the page from the
    # params its stream token was signed with, and morph it into the browser.
    DEFAULT_HANDLER = proc do |_evt|
      browser.patch_elements load(params)
    end

    class PageContext
      # @param params [Hash] the page's params, decoded by {Page.query_schema}
      #   from its stream token
      def initialize(sse, ctx, page, params:)
        @context = ctx
        @browser = sse
        @params = params
        @page_id = sse.signals['page_id']
        @page_key = sse.signals['page_key']
        @page = page
      end

      # Run the page's reaction for +evt+, if any.
      #
      # A handler registered for the message's exact class wins: it was
      # written for that message's shape and reads its payload. Otherwise,
      # when either the message's own +type+ or its +correlation_type+ — the
      # type at the root of its causal chain — is one the page {.on reacts
      # to} without a block, the page reloads. At most one of the two runs.
      def react(evt)
        if (handler = @page.reactions[evt.class])
          self.instance_exec(evt, &handler)
        elsif @page.reloads_on?(evt)
          self.instance_exec(evt, &DEFAULT_HANDLER)
        end
      end

      # React to every message on +channel+ until it stops, coalescing reloads.
      #
      # A fiber reads the channel into a local queue, and this fiber runs the
      # reactions from it, in arrival order. Messages with a handler of their
      # own each run it: the handler may read the payload. Reloads read only
      # current state, so a reload still waiting in the queue when a newer one
      # arrives is skipped, and the newer one renders in its place. A burst
      # of reloads arriving while a render is in flight therefore yields one
      # more render once it finishes, however long the burst, and a lone
      # reload renders as soon as it arrives.
      #
      # Exceptions raised by a reaction propagate from here, as they do from
      # {#react}.
      #
      # @param channel [#start] a pubsub channel
      # @return [void]
      def run(channel)
        Sync do |task|
          pending = Async::Queue.new
          latest_reload = 0
          reader = task.async do
            channel.start do |evt, _channel|
              if @page.reactions[evt.class]
                pending << [evt, nil]
              elsif @page.reloads_on?(evt)
                pending << [evt, latest_reload += 1]
              end
            end
          ensure
            pending.close
          end

          begin
            while (evt, reload = pending.pop)
              next if reload && reload != latest_reload

              react(evt)
            end
          ensure
            reader.stop
          end
        end
      end

      private

      def load(params)
        @page.load(params, context)
      end

      attr_reader :browser, :context, :params, :page_key, :page_id
    end

    private def page_key = self.class.page_key

    # Mark this page as the one rendering for the duration of its template,
    # so nested command forms register on it. Restores whatever was there
    # before, which is +nil+ except for a page rendered inside another.
    private def around_template(&)
      previous = Thread.current[RENDERING_KEY]
      Thread.current[RENDERING_KEY] = self.class
      super(&)
    ensure
      Thread.current[RENDERING_KEY] = previous
    end

    # The pubsub channel patterns this page subscribes to for live updates.
    # The layout asks the page it renders and signs the answer into the
    # page's stream URL (see {.stream_token}), so the browser can only
    # subscribe to what the page named. Return one pattern as a String, an
    # Array of several to receive more than one stream, such as an entity's
    # updates and system-wide ones, or +[]+ or +nil+ for a page that takes no
    # live updates: the layout then opens no stream for it.
    #
    #   def channel_names = "orders.#{channel_segment(@order.id)}"
    #
    #   def channel_names
    #     return [] if @current_step  # a historic snapshot
    #
    #     ["orders.#{channel_segment(@order.id)}", "accounts.#{channel_segment(@order.account_id)}.>"]
    #   end
    #
    # Interpolate values through {#channel_segment}: an id taken from the URL
    # could otherwise be +>+ and turn the channel into a wildcard, which the
    # page would then sign.
    #
    # The answer is fixed when the page first renders: reactions that
    # re-render it, and the browser's reconnects, keep the same stream. The
    # default is +['system']+, where messages go that no channel resolver
    # routes elsewhere, so a page can add its own with +super + [...]+.
    #
    # @return [String, Array<String>, nil] exact channel names or wildcard patterns
    def channel_names = [DEFAULT_CHANNEL]

    # +value+ as a String, checked to be exactly one plain segment of a channel
    # name, for interpolating into {#channel_names}. Wildcards are written into the
    # pattern itself (+"orders.>"+), never taken from a value.
    #
    # @param value [#to_s]
    # @return [String]
    # @raise [ArgumentError] if +value+ is blank, contains +.+, or is +*+ or +>+
    private def channel_segment(value)
      segment = value.to_s
      if segment.empty? || segment.include?(PubSub::Pattern::SEGMENT_SEPARATOR) || segment == '*' || segment == '>'
        raise ArgumentError, "#{value.inspect} is not a single plain channel name segment"
      end

      segment
    end

    def page_signals
      { page_key: }
    end

    private def session = context.session

    class << self
      # The URL pattern the page is mounted on, with named segments
      # (+/accounts/:id/expenses+). Setting it recompiles {.query_schema}, so
      # the segments are picked up whether +path+ is declared before or after
      # the schema.
      #
      # @param p [String, nil]
      # @return [String, nil]
      def path(p = nil)
        if p
          @path = p
          compile_query_schema!
        end
        @path
      end

      # The schema the page's path and query params are decoded through, on
      # the GET request and on every SSE connect and reaction. Only its keys
      # reach {.load}: anything a request carries that isn't declared is
      # dropped.
      #
      # Declare the types in their decoded form. The schema is compiled
      # through +Plumb::Codec::Forms+, so a +Types::Date+ field accepts
      # +"2026-11-01"+ and a +Types::Boolean+ accepts +"true"+ or +"1"+. Each
      # path segment is in the schema as a +String+ unless declared here.
      #
      #   path '/accounts/:id/expenses'
      #   query_schema(
      #     id: Types::UUID::V4,  # the path segment
      #     from?: Types::Date    # an optional query param
      #   )
      #
      # Each call merges into the schema declared so far, starting from the
      # superclass's, and a field declared again takes its new type.
      #
      # Without arguments, returns the schema: the declared one merged over
      # the path segments, or just the segments (+Types::Hash[id: String]+),
      # or an empty one for a page with neither.
      #
      # @param schema [Plumb::HashClass, nil] a ready +Types::Hash[...]+
      # @param fields [Hash{Symbol => Object}] field types, as given to +Types::Hash[]+
      # @return [Plumb::HashClass]
      # @raise [Plumb::TypeError] if a field's type has no Forms encoder
      def query_schema(schema = nil, **fields)
        if schema || fields.any?
          schema ||= Types::Hash[fields]
          @declared_query_schema = @declared_query_schema ? @declared_query_schema + schema : schema
          compile_query_schema!
        end
        @query_schema || compile_query_schema!
      end

      # {.query_schema} compiled through +Plumb::Codec::Forms+: takes the
      # String-valued params of a request or of the +params+ signal, with
      # Symbol or String keys, and returns them typed and filtered.
      #
      # @return [Plumb::Composable]
      def query_decoder
        query_schema
        @query_decoder
      end

      # Decode raw path and query params through the page's {.query_schema}.
      #
      # @param params [Hash, nil] String-valued params, Symbol or String keys
      # @return [Plumb::Result] +#value+ is the decoded, filtered Hash when
      #   +#valid?+; +#errors+ a +{key => message}+ Hash otherwise
      def parse_params(params)
        query_decoder.resolve(params || {})
      end

      # Page classes by {.page_key}, so a stream token can name its page.
      # {App.page} registers the pages it mounts.
      #
      # @return [Hash{String => Class<Page>}]
      def registry
        @registry ||= {}
      end

      def page_key = self.path || self.name

      # @param klass [Class<Page>]
      # @return [self]
      def register(klass)
        registry[klass.page_key] = klass
        self
      end

      # Sign +page+'s live updates stream into a token for its URL,
      # +/_updates/<token>+: the page's key, the +params+ it was rendered
      # with, its {#channel_names}, and a digest of the session it was rendered
      # in. {.resolve_stream} turns it back into a {Stream}.
      #
      # A session that has no id yet is given one, by storing {SESSION_KEY}
      # in it, so the stream has a {.session_channel}.
      #
      # Only the params the page's {.query_schema} declares are signed.
      # Returns +nil+, for no stream, when the page names no channels, its
      # class isn't the one {.registry} holds for its key (it wasn't mounted
      # with {App.page}), or +params+ don't decode.
      #
      # @param page [Page] the page being rendered
      # @param params [Hash] the request's raw params
      # @param ctx [Sidereal::App] the request's app instance
      # @param signer [#generate]
      # @return [String, nil]
      # @raise [ArgumentError] if a channel pattern is invalid
      def stream_token(page, params, ctx, signer: Sidereal.signer)
        page_class = page.class
        return unless registry[page_class.page_key].equal?(page_class)

        channels = Array(page.channel_names)
        return if channels.empty?

        channels.each { |pattern| PubSub::Pattern.validate_subscription!(pattern) }
        decoded = page_class.parse_params(params)
        return unless decoded.valid?

        signed_params = params.to_h.select { |key, _| decoded.value.key?(key.to_sym) }
        start_session(ctx)
        signer.generate(
          { 'page' => page_class.page_key, 'params' => signed_params, 'channels' => channels, 'session' => session_digest(ctx) },
          purpose: STREAM_PURPOSE
        )
      end

      # The {Stream} +token+ stands for, or +nil+ unless it was signed with
      # this signer's secret, in the session +ctx+ carries, for a page in
      # {.registry} whose params still decode. A session that has since
      # been renewed, or a token from before the secret changed, gets +nil+.
      # The stream's channels are the page's, and the session's
      # {.session_channel} when it has one.
      #
      # A request with no session at all, as from a browser that refuses
      # cookies, gets the page's channels without a session channel, rather
      # than +nil+, which would reload the page for a session it never
      # keeps.
      #
      # @param token [String] from {.stream_token}
      # @param ctx [Sidereal::App] the request's app instance
      # @param signer [#verify]
      # @return [Stream, nil]
      def resolve_stream(token, ctx, signer: Sidereal.signer)
        data = STREAM_DATA.resolve(signer.verify(token, purpose: STREAM_PURPOSE))
        return unless data.valid?

        data = data.value
        session = session_digest(ctx)
        return unless session.nil? || data['session'] == session

        page_class = registry[data['page']]
        return unless page_class

        channels = data['channels']
        params = page_class.parse_params(data['params'])
        return unless params.valid?

        channels += [session_channel_for(session)] if session
        Stream.new(page_class:, params: params.value, channels:)
      end

      # The private channel of the session +ctx+ carries, which every page
      # stream in it subscribes to, or +nil+ without a session id.
      #
      # @param ctx [Sidereal::App]
      # @return [String, nil]
      def session_channel(ctx)
        digest = session_digest(ctx)
        session_channel_for(digest) if digest
      end

      # The private channel of the session whose {.session_digest} is
      # +digest+, as a message's {SESSION_DIGEST_KEY} metadata holds it.
      #
      # @param digest [String]
      # @return [String]
      def session_channel_for(digest) = "#{SESSION_CHANNEL_PREFIX}.#{digest}"

      # A digest of the session id +ctx+ carries, or +nil+ without one, or
      # when +rack.session+ is a plain Hash with no id. Rack assigns a session
      # its id the first time something is stored in it, and only changes it
      # when the session is renewed.
      #
      # The id is digested in its public form, which it has however the
      # session store hands it back: a +Rack::Session::SessionId+, or the
      # String a JSON cookie coder turns it into.
      #
      # @param ctx [Sidereal::App]
      # @return [String, nil]
      def session_digest(ctx)
        session = ctx.request.env['rack.session']
        id = session.id if session.respond_to?(:id)
        return if id.nil? || id.to_s.empty?

        OpenSSL::Digest::SHA256.hexdigest("#{SESSION_DIGEST_PREFIX}#{id}")[0, 32]
      end

      private def start_session(ctx)
        session = ctx.request.env['rack.session']
        return unless session.respond_to?(:id) && session.respond_to?(:[]=)

        session[SESSION_KEY] = true if session.id.nil?
      end

      # Stream live updates for the page at +params+ into +sse+, until
      # +channel+ stops. The page renders once first, so a tab that
      # reconnects, as browsers do when a tab regains focus, catches up on
      # whatever it missed. It then reacts to each message on +channel+.
      #
      # @param channel [#start] a pubsub channel, subscribed to {#channel_names}
      # @param sse [#patch_elements] the browser's SSE stream
      # @param params [Hash] the page's params, decoded by {.query_schema}
      # @param ctx [Sidereal::App] the request's app instance
      # @return [void]
      def stream(channel, sse, params, ctx)
        sse.patch_elements load(params, ctx)
        PageContext.new(sse, ctx, self, params:).run(channel)
      end

      # Handlers keyed by message class, matched on the exact class of an
      # incoming message. Populated by {.on} with a block.
      #
      # @return [Hash{Class => Proc}]
      def reactions
        @reactions ||= {}
      end

      # Message type strings the page reloads on. A message matches when its
      # own +type+ or its +correlation_type+ is in this set, so registering a
      # type here covers that message whenever it arrives and everything
      # produced as a consequence of it — the events a handler emitted, the
      # commands those triggered, and so on — without the page knowing each
      # downstream type. Populated by {.on} without a block, which is also
      # what every command form rendered inside the page does (see
      # {Components::Command}).
      #
      # @return [Set<String>]
      def correlation_types
        @correlation_types ||= Set.new
      end

      # Whether +message+ triggers the reload registered by a block-less {.on}:
      # its own type is in {.correlation_types}, or the root of its chain is.
      #
      # @param message [Sourced::Message]
      # @return [Boolean]
      def reloads_on?(message)
        correlation_types.include?(message.type) || correlation_types.include?(message.correlation_type)
      end

      # The page class currently rendering in this fiber, or +nil+ outside a
      # page render. Set by {#around_template}.
      #
      # @return [Class<Page>, nil]
      def rendering
        Thread.current[RENDERING_KEY]
      end

      # Whether command forms rendered inside this page register the page to
      # reload on their command — the default. See {.disable_causal_reactivity!}.
      #
      # @return [Boolean]
      def causal_reactivity? = @causal_reactivity != false

      # Stop command forms rendered inside this page from registering it to
      # reload on their command and its consequences. The page then reacts
      # only to what it names with {.on}, block-less or not, which still
      # matches by own type or chain root. Inherited by subclasses.
      #
      # @return [self]
      def disable_causal_reactivity!
        @causal_reactivity = false
        self
      end

      def load(params, ctx)
        raise NotImplementedError
      end

      def interested?(sse)
        sse.signals['page_key'] == page_key
      end

      def view_template(&block)
        define_method :view_template, &block
      end

      # Register a reaction to +sources+: message classes, or anything that
      # answers +sidereal_events+ with the message classes it stands for.
      # +on(Donation)+ registers every event that changes the +Donation+
      # decider's state, and +on(GamesProjector)+ its +Projected+ signal
      # (see {Integrations::Sourced}, which gives Sourced reactors that
      # answer). A plain object can define +sidereal_events+ too.
      #
      # With a block, the block runs for messages of exactly those classes
      # (see {.reactions}). Without one, the page reloads for any message of
      # those types and for any message whose causal chain starts with one of
      # them (see {.correlation_types}): +on AddTodo+ re-renders the page
      # when the +AddTodo+ command comes back over pubsub, and equally when
      # an event handled from it does; +on MyProjector::Projected+ re-renders
      # on every projector signal, whichever command produced its batch.
      #
      # @param sources [Array<Class<Sourced::Message>, #sidereal_events>]
      # @return [self]
      # @raise [ArgumentError] with no sources, or a source that expands to nothing
      def on(*sources, &block)
        message_classes = sources.flat_map { |source| expand_source(source) }
        raise ArgumentError, 'at least one message class is required' if message_classes.empty?

        message_classes.each do |message_class|
          if block
            reactions[message_class] = block
          else
            correlation_types << message_class.type
          end
        end
        self
      end

      def inherited(subclass)
        super
        reactions.each do |message_class, block|
          subclass.reactions[message_class] = block
        end
        subclass.correlation_types.merge(correlation_types)
        subclass.query_schema(@declared_query_schema) if @declared_query_schema
        subclass.disable_causal_reactivity! unless causal_reactivity?
      end

      private

      # The names of the path's +:segment+s.
      def path_segments
        return [] unless path

        path.split('/').filter_map { |segment| segment.delete_prefix(':').to_sym if segment.start_with?(':') }
      end

      # Build {.query_schema} and its decoder from the path segments and the
      # declared schema. A schema with no keys would let any Hash through, so
      # its decoder discards everything instead.
      def compile_query_schema!
        schema = Types::Hash[path_segments.to_h { |name| [name, Types::String] }]
        schema += @declared_query_schema if @declared_query_schema
        @query_decoder = if schema._schema.empty?
          Types::Hash.transform(::Hash) { {} }
        else
          Plumb::Codec::Forms >> schema
        end
        @query_schema = schema
      end

      # The message classes a source given to {.on} stands for.
      def expand_source(source)
        return [source] unless source.respond_to?(:sidereal_events)

        events = Array(source.sidereal_events)
        raise ArgumentError, "#{source} answers sidereal_events with nothing to react to" if events.empty?

        events
      end
    end

    # Default reactions to framework-dispatched system notifications.
    # Stack toasts at the top of the body. Subclasses inherit these via
    # the {.inherited} hook above; user pages can override with their
    # own +on(NotifyRetry)+ / +on(NotifyFailure)+ blocks. Will be
    # gated on a development-only flag in a future iteration.
    on Sidereal::System::NotifyRetry do |evt|
      browser.patch_elements(
        Sidereal::Components::SystemNotifyRetry.new(evt),
        mode: 'prepend',
        selector: '#sidereal-sysnotify-stack'
      )
    end

    on Sidereal::System::NotifyFailure do |evt|
      browser.patch_elements(
        Sidereal::Components::SystemNotifyFailure.new(evt),
        mode: 'prepend',
        selector: '#sidereal-sysnotify-stack'
      )
    end
  end
end
