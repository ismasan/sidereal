# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::Components::BasicLayout do
  let(:page_class) do
    Class.new(Sidereal::Page) do
      path '/test'

      def view_template
        div { 'page content' }
      end
    end
  end

  # Layout needs a Rack request in context for BaseComponent#params and url()
  let(:env) { { 'router.params' => {}, 'rack.url_scheme' => 'http', 'HTTP_HOST' => 'example.com' } }
  let(:context) do
    Struct.new(:request) { include Sidereal::RequestHelpers }.new(Rack::Request.new(env))
  end

  let(:page) { page_class.new }
  let(:html) { described_class.new(page).call(context:) { page.call } }

  it 'renders its styles unescaped' do
    style = html[%r{<style>(.*?)</style>}m, 1]

    expect(style).to eq(described_class::STYLES)
  end

  it 'includes the Datastar script once' do
    expect(html.scan('starfederation/datastar').size).to eq(1)
  end

  it 'declares the page signals on body once, as data-signals' do
    body = html[/<body[^>]*>/]

    expect(body).to eq(%(<body data-signals="{&quot;page_key&quot;:&quot;/test&quot;,&quot;params&quot;:{}}">))
  end

  it 'renders the page' do
    expect(html).to include('<div class="page"><div>page content</div></div>')
  end
end
