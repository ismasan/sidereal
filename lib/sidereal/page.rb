# frozen_string_literal: true

require_relative 'components/base_component'

module Sidereal
  class Page < BaseComponent
    METHOD_PREFIX = '__on_'
    BLANK_HASH = {}.freeze

    def params
      context.request.env.fetch('router.params', BLANK_HASH)
    end

    private def command(klass, *args, &block)
      render Sidereal::Components::Command.new(klass, *args, &block)
    end

    private def page_key = self.class.page_key

    private def page_signals
      { page_key:, params: context.request.params }
    end

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
        sse.patch_elements page_class.load(sse.signals['params'], ctx)

        page_context = PageContext.new(sse, ctx, page_class)

        channel.start do |evt, _channel|
          Console.info "Event: #{evt.inspect}"
          page_context.react(evt)
        end
      end

      def reactions
        @reactions ||= {}
      end

      DEFAULT_HANDLER = proc do |_evt, _state|
        browser.patch_element build(params)
      end

      class PageContext
        def initialize(sse, ctx, page)
          @context = ctx
          @browser = sse
          @params = sse.signals['params']
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

      def load(params, ctx)
        raise NotImplementedError
      end

      def interested?(sse)
        sse.signals['page_key'] == page_key
      end

      def view_template(&block)
        define_method :view_template, &block
      end

      def on(message_class, &block)
        reactions[message_class] = block || DEFAULT_HANDLER
        self
      end
    end
  end
end
