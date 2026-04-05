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

  # Layout needs a Rack request in context for BaseComponent#params
  let(:env) { { 'router.params' => {} } }
  let(:request) { Rack::Request.new(env) }
  let(:context) { Struct.new(:request).new(request) }

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
      expect(html).to include("data-init=\"@get('/updates')\"")
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
