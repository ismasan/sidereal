# frozen_string_literal: true

require_relative 'components/base_component'

module Sidereal
  class Page < Components::BaseComponent
    METHOD_PREFIX = '__on_'

    DEFAULT_HANDLER = proc do |_evt, _state|
      browser.patch_element build(params)
    end

    class PageContext
      def initialize(sse, ctx, page)
        @context = ctx
        @browser = sse
        @params = Page.normalize_params(sse.signals['params'])
        @page_id = sse.signals['page_id']
        @page_key = sse.signals['page_key']
        @page = page
      end

      def react(evt)
        if (handler = @page.reactions[evt.class])
          self.instance_exec(evt, &handler)
        end
      end

      private

      def load(params)
        @page.load(params, context)
      end

      attr_reader :browser, :context, :params, :page_key, :page_id
    end

    private def page_key = self.class.page_key

    def channel_name = 'system'

    def page_signals
      { page_key: }
    end

    private def session = context.session

    class << self
      def path(p = nil)
        @path = p if p
        @path
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

        # Build on connect
        sse.patch_elements page_class.load(normalize_params(sse.signals['params']), ctx)

        page_context = PageContext.new(sse, ctx, page_class)

        channel.start do |evt, _channel|
          page_context.react(evt)
        end
      end

      def reactions
        @reactions ||= {}
      end

      def load(params, ctx)
        raise NotImplementedError
      end

      def normalize_params(params)
        (params || {}).transform_keys(&:to_sym)
      end

      def interested?(sse)
        sse.signals['page_key'] == page_key
      end

      def view_template(&block)
        define_method :view_template, &block
      end

      def on(*message_classes, &block)
        raise ArgumentError, 'at least one message class is required' if message_classes.empty?

        message_classes.each do |message_class|
          reactions[message_class] = block || DEFAULT_HANDLER
        end
        self
      end

      def inherited(subclass)
        super
        reactions.each do |message_class, block|
          subclass.reactions[message_class] = block
        end
      end
    end
  end
end
