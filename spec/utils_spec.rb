# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::Utils do
  describe '.camel_case' do
    it 'capitalises each word and joins them' do
      expect(described_class.camel_case('clock tick')).to eq('ClockTick')
    end

    it 'splits on any non-alphanumeric run' do
      expect(described_class.camel_case('flash-sale_campaign')).to eq('FlashSaleCampaign')
      expect(described_class.camel_case('one  two   three')).to eq('OneTwoThree')
    end

    it 'preserves digits as-is (callers wanting a valid Ruby constant must add their own letter prefix)' do
      expect(described_class.camel_case('5 minute')).to eq('5Minute')
    end

    it 'handles a single word' do
      expect(described_class.camel_case('hello')).to eq('Hello')
    end

    it 'returns an empty string for an empty input' do
      expect(described_class.camel_case('')).to eq('')
    end
  end

  describe '.snake_case' do
    it 'converts a CamelCase string with namespace' do
      expect(described_class.snake_case('ChatApp::Commander')).to eq('chat_app_commander')
    end

    it 'inserts underscores at acronym boundaries' do
      expect(described_class.snake_case('HTTPServer')).to eq('http_server')
      expect(described_class.snake_case('XMLParser')).to eq('xml_parser')
    end

    it 'collapses any non-alphanumeric run into a single underscore' do
      expect(described_class.snake_case('foo-bar baz')).to eq('foo_bar_baz')
    end

    it 'trims leading and trailing underscores' do
      expect(described_class.snake_case('__hello__')).to eq('hello')
    end

    it 'is idempotent for an already snake_case string' do
      expect(described_class.snake_case('already_snake')).to eq('already_snake')
    end
  end
end
