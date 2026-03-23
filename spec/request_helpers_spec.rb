# frozen_string_literal: true

require 'spec_helper'
require 'sidereal/request_helpers'

RSpec.describe Sidereal::RequestHelpers do
  let(:host_class) do
    Class.new do
      include Sidereal::RequestHelpers
      attr_reader :request

      def initialize(request)
        @request = request
      end
    end
  end

  def build(url, env = {})
    host_class.new(Rack::Request.new(Rack::MockRequest.env_for(url, env)))
  end

  describe '#url' do
    it 'returns the absolute URL for the current request path' do
      helper = build('http://example.com/items')
      expect(helper.url).to eq('http://example.com/items')
    end

    it 'returns the absolute URL for a given path' do
      helper = build('http://example.com/items')
      expect(helper.url('/other')).to eq('http://example.com/other')
    end

    it 'returns an already-absolute URI unchanged' do
      helper = build('http://example.com/')
      expect(helper.url('https://elsewhere.com/foo')).to eq('https://elsewhere.com/foo')
    end

    it 'includes the port when it is non-standard' do
      helper = build('http://example.com:8080/items')
      expect(helper.url).to eq('http://example.com:8080/items')
    end

    it 'omits the port when it is the default for the scheme' do
      helper = build('http://example.com:80/items')
      expect(helper.url).to eq('http://example.com/items')
    end

    it 'uses https when the request is secure' do
      helper = build('https://example.com/items')
      expect(helper.url).to eq('https://example.com/items')
    end

    it 'includes SCRIPT_NAME when mounted as a sub-app' do
      helper = build('http://example.com/items', 'SCRIPT_NAME' => '/app')
      expect(helper.url('/items')).to eq('http://example.com/app/items')
    end

    it 'omits SCRIPT_NAME when add_script_name is false' do
      helper = build('http://example.com/items', 'SCRIPT_NAME' => '/app')
      expect(helper.url('/items', true, false)).to eq('http://example.com/items')
    end

    it 'returns a relative path when absolute is false' do
      helper = build('http://example.com/items')
      expect(helper.url('/items', false)).to eq('/items')
    end
  end
end
