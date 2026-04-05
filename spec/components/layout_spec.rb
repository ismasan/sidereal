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
    klass = Class.new(described_class) do
      def view_template
        html do
          head { sidereal_head }
          body do
            div(data: sidereal_signals.to_h) do
              yield
            end
            sidereal_foot
          end
        end
      end
    end
    klass
  end

  let(:layout) { layout_class.new(page) }

  # Layout needs a Rack request in context for BaseComponent#params
  let(:env) { { 'router.params' => {} } }
  let(:request) { Rack::Request.new(env) }
  let(:context) { Struct.new(:request).new(request) }

  def render_layout
    layout.call(context:) { page.call }
  end

  describe '#sidereal_head' do
    it 'includes the Datastar JS script tag' do
      html = render_layout
      expect(html).to include('cdn.jsdelivr.net/gh/starfederation/datastar')
      expect(html).to include('type="module"')
    end
  end

  describe '#sidereal_foot' do
    it 'renders a div that initializes SSE via GET /updates' do
      html = render_layout
      expect(html).to include("data-init=\"@get('/updates')\"")
    end
  end

  describe '#sidereal_signals' do
    it 'includes the page_key signal' do
      html = render_layout
      expect(html).to include('data-signals')
      expect(html).to include('page_key')
      expect(html).to include('/test')
    end

    it 'includes the params signal' do
      html = render_layout
      expect(html).to include('params')
    end
  end

  describe 'rendering page content' do
    it 'yields the page content within the layout' do
      html = render_layout
      expect(html).to include('page content')
    end
  end
end
