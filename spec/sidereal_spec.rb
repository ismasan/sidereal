# frozen_string_literal: true

RSpec.describe Sidereal do
  it "has a version number" do
    expect(Sidereal::VERSION).not_to be nil
  end

  describe '.configure' do
    it 'yields a Configuration object' do
      yielded = nil
      Sidereal.configure { |c| yielded = c }
      expect(yielded).to be_a(Sidereal::Configuration)
    end
  end
end

RSpec.describe Sidereal::Configuration do
  subject(:config) { described_class.new }

  it 'defaults workers to 1' do
    expect(config.workers).to eq(1)
  end

  it 'defaults store to Store::Memory' do
    expect(config.store).to eq(Sidereal::Store::Memory.instance)
  end

  it 'defaults pubsub to PubSub::Memory' do
    expect(config.pubsub).to eq(Sidereal::PubSub::Memory.instance)
  end

  it 'defaults dispatcher to Sidereal::Dispatcher' do
    expect(config.dispatcher).to eq(Sidereal::Dispatcher)
  end

  it 'allows setting a custom store' do
    custom_store = Object.new
    config.store = custom_store
    expect(config.store).to eq(custom_store)
  end

  it 'allows setting a custom pubsub' do
    custom_pubsub = Object.new
    config.pubsub = custom_pubsub
    expect(config.pubsub).to eq(custom_pubsub)
  end

  it 'allows setting a custom dispatcher class' do
    custom_dispatcher = Class.new
    config.dispatcher = custom_dispatcher
    expect(config.dispatcher).to eq(custom_dispatcher)
  end
end
