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
    # The stream URL's token, from the SSE init div in +html+.
    def stream_token(html) = html[%r{data-init="@get\('/_updates/([^']+)'\)"}, 1]

    it 'points the SSE init div at a signed stream for the page, its params and its channels' do
      Sidereal::Page.register(page_class)
      html = render_layout

      stream = Sidereal::Page.resolve_stream(stream_token(html), context)
      expect(stream).to eq(Sidereal::Page::Stream.new(page_class:, params: {}, channels: ['system']))
    end

    it 'signs the channels the page instance names, and only the params its schema declares' do
      typed_page_class = Class.new(Sidereal::Page) do
        path '/typed/:id'
        query_schema(id: Sidereal::Types::Integer)

        def initialize(user:) = @user = user
        def channel_names = ["users.#{@user}", 'system']
        def view_template = div { 'typed' }
      end
      Sidereal::Page.register(typed_page_class)
      typed_env = env.merge('router.params' => { id: '7', other: 'x' })
      typed_context = Struct.new(:request) { include Sidereal::RequestHelpers }.new(Rack::Request.new(typed_env))
      html = layout_class.new(typed_page_class.new(user: 'ada')).call(context: typed_context) { page.call }

      expect(Sidereal.signer.verify(stream_token(html), purpose: Sidereal::Page::STREAM_PURPOSE)).to include(
        'params' => { 'id' => '7' }, 'channels' => ['users.ada', 'system']
      )
      expect(Sidereal::Page.resolve_stream(stream_token(html), typed_context).params).to eq({ id: 7 })
    end

    it 'prefixes the SSE updates path with SCRIPT_NAME when app is mounted at a sub-path' do
      Sidereal::Page.register(page_class)
      mounted_env = env.merge('SCRIPT_NAME' => '/myapp')
      mounted_request = Rack::Request.new(mounted_env)
      mounted_context = Struct.new(:request) { include Sidereal::RequestHelpers }.new(mounted_request)
      html = layout.call(context: mounted_context) { page.call }
      expect(html).to match(%r{data-init="@get\('/myapp/_updates/[^']+'\)"})
    end

    it 'omits the SSE init div when the page subscribes to no channels' do
      silent_page_class = Class.new(Sidereal::Page) do
        path '/silent'
        def channel_names = []
        def view_template = div { 'no sse' }
      end
      Sidereal::Page.register(silent_page_class)
      html = render_layout(layout_class.new(silent_page_class.new))
      expect(html).not_to include('data-init')
    end

    it 'omits the SSE init div for a page class no app mounted' do
      html = render_layout
      expect(html).not_to include('data-init')
    end

    it 'omits the SSE init div when the request params do not decode' do
      typed_page_class = Class.new(Sidereal::Page) do
        path '/typed/:id'
        query_schema(id: Sidereal::Types::Integer)
        def view_template = div { 'typed' }
      end
      Sidereal::Page.register(typed_page_class)
      bad_env = env.merge('router.params' => { id: 'nope' })
      bad_context = Struct.new(:request) { include Sidereal::RequestHelpers }.new(Rack::Request.new(bad_env))
      html = layout_class.new(typed_page_class.new).call(context: bad_context) { page.call }
      expect(html).not_to include('data-init')
    end

    it 'raises for a channel pattern the pubsub would reject' do
      bad_page_class = Class.new(Sidereal::Page) do
        path '/bad-channel'
        def channel_names = ['orders..1']
        def view_template = div { 'bad' }
      end
      Sidereal::Page.register(bad_page_class)
      expect { render_layout(layout_class.new(bad_page_class.new)) }.to raise_error(ArgumentError, /empty segment/)
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
