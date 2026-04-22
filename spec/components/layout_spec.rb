# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::Components::Layout do
  let(:page_class) do
    Class.new(Sidereal::Page) do
      path '/test'

      def view_template
        div { 'page content' }
      end
    end
  end

  let(:page) { page_class.new }

  let(:layout_class) do
    Class.new(described_class) do
      def view_template
        html do
          head do
            title { 'Test' }
          end
          body do
            render page
          end
        end
      end
    end
  end

  let(:layout) { layout_class.new(page) }

  # Layout needs a Rack request in context for BaseComponent#params and url()
  let(:env) { { 'router.params' => {}, 'rack.url_scheme' => 'http', 'HTTP_HOST' => 'example.com' } }
  let(:request) { Rack::Request.new(env) }
  let(:context) do
    ctx_class = Struct.new(:request) do
      include Sidereal::RequestHelpers
    end
    ctx_class.new(request)
  end

  def render_layout(component = layout)
    component.call(context:) { page.call }
  end

  describe '#head' do
    it 'appends the Datastar JS script tag after yielded content' do
      html = render_layout
      expect(html).to include('cdn.jsdelivr.net/gh/starfederation/datastar')
      expect(html).to include('type="module"')
    end

    it 'preserves content yielded by the subclass' do
      html = render_layout
      expect(html).to include('<title>Test</title>')
    end
  end

  describe '#body' do
    it 'appends the SSE init div after yielded content' do
      html = render_layout
      expect(html).to include("data-init=\"@get('/updates/system')\"")
    end

    it 'uses the page channel name for the SSE updates path' do
      page_with_channel_class = Class.new(Sidereal::Page) do
        path '/custom'

        def channel_name = 'items.42'

        def view_template
          div { 'page content' }
        end
      end
      html = render_layout(layout_class.new(page_with_channel_class.new))
      expect(html).to include("data-init=\"@get('/updates/items.42')\"")
    end

    it 'prefixes the SSE updates path with SCRIPT_NAME when app is mounted at a sub-path' do
      mounted_env = env.merge('SCRIPT_NAME' => '/myapp')
      mounted_request = Rack::Request.new(mounted_env)
      mounted_context = Struct.new(:request) { include Sidereal::RequestHelpers }.new(mounted_request)
      html = layout.call(context: mounted_context) { page.call }
      expect(html).to include("data-init=\"@get('/myapp/updates/system')\"")
    end

    it 'omits the SSE init div when page channel_name is nil' do
      silent_page_class = Class.new(Sidereal::Page) do
        path '/silent'
        def channel_name = nil
        def view_template = div { 'no sse' }
      end
      html = render_layout(layout_class.new(silent_page_class.new))
      expect(html).not_to include('data-init')
    end

    it 'includes page_key and params signals on the body tag' do
      html = render_layout
      expect(html).to include('data-signals')
      expect(html).to include('page_key')
      expect(html).to include('/test')
      expect(html).to include('params')
    end

    it 'merges extra signals passed via data[:signals]' do
      layout_with_signals = Class.new(described_class) do
        def view_template
          html do
            head {}
            body(data: { signals: { custom: 'value' } }) do
              render page
            end
          end
        end
      end

      html = render_layout(layout_with_signals.new(page))
      expect(html).to include('custom')
      expect(html).to include('value')
      # still has the default signals
      expect(html).to include('page_key')
    end

    it 'preserves non-signal data attributes' do
      layout_with_data = Class.new(described_class) do
        def view_template
          html do
            head {}
            body(data: { foo: 'bar' }) do
              render page
            end
          end
        end
      end

      html = render_layout(layout_with_data.new(page))
      expect(html).to include('data-foo="bar"')
      expect(html).to include('data-signals')
    end
  end

  describe 'rendering page content' do
    it 'yields the page content within the layout' do
      html = render_layout
      expect(html).to include('page content')
    end
  end
end
