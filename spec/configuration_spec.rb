# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::Configuration do
  describe '#use' do
    it 'applies an integration via #setup(config, **opts) and returns self' do
      received = nil
      integration = Object.new
      integration.define_singleton_method(:setup) do |config, **opts|
        received = [config, opts]
        config
      end

      config = described_class.new
      result = config.use(integration, foo: 1, bar: 2)

      expect(result).to be(config)
      expect(received).to eq([config, { foo: 1, bar: 2 }])
    end

    it 'raises for an object that does not respond to #setup' do
      config = described_class.new
      expect { config.use(Object.new) }.to raise_error(StandardError)
    end
  end
end
