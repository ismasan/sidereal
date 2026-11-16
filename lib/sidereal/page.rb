# frozen_string_literal: true

require 'set'
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

    # Reaction run for a message whose class has no handler of its own but
    # whose +correlation_type+ the page reacts to: reload the page from the
    # current signal params and morph it into the browser.
    DEFAULT_HANDLER = proc do |_evt|
      browser.patch_elements load(params)
    end

    class PageContext
      # @param params [Hash] the page's decoded params. Defaults to decoding
      #   the +params+ signal through the page's {Page.query_schema}, raising
      #   +Plumb::ParseError+ if they don't satisfy it.
      def initialize(sse, ctx, page, params: page.query_decoder.parse(sse.signals['params'] || {}))
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

    def channel_name = 'system'

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

      def registry
        @registry ||= {}
      end

      def page_key = self.path || self.name

      def register(klass)
        registry[klass.page_key] = klass
        self
      end

      def subscribe(channel, sse, ctx)
        # on connect, we make sure to render the page again
        # so that browser tabs reconnecting on focus catch up to the latest state
        page_key = sse.signals['page_key']
        return unless page_key
        page_class = registry[page_key]
        return unless page_class

        # Params a client tampered with into failing the schema get no page.
        params = page_class.parse_params(sse.signals['params'])
        return unless params.valid?

        # Build on connect
        sse.patch_elements page_class.load(params.value, ctx)

        page_context = PageContext.new(sse, ctx, page_class, params: params.value)

        channel.start do |evt, _channel|
          page_context.react(evt)
        end
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
