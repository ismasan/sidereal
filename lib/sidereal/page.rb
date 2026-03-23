# frozen_string_literal: true

require_relative 'components/base_component'

module Sidereal
  class BasicLayout < BaseComponent
    def initialize(page)
      @page = page
    end

    def view_template
      doctype

      html do
        head do
          meta(name: 'viewport', content: 'width=device-width, initial-scale=1.0')
          title { 'basic' }
          script(type: "module", src: "https://cdn.jsdelivr.net/gh/starfederation/datastar@1.0.0-RC.8/bundles/datastar.js")
        end
        body do
          div(class: 'page') do
            render @page
          end

          onload = _d.init.get('/updates')
          # onload needs to be at the end
          # to make sure to collect all signals on the page
          div(data: onload.to_h)
        end
      end
    end
  end

  class Page < BaseComponent
    METHOD_PREFIX = '__on_'

    private def command(klass, *args, &block)
      render Sidereal::Components::Command.new(klass, *args, &block)
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

        ctxs = registry.values
          .filter { |p| p.interested?(sse) }
          .map { |p| PageContext.new(sse, ctx, p) }

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
