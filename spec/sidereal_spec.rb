# frozen_string_literal: true

DispatchBangCmd = Sidereal::Message.define('sidereal_spec.do_thing') do
  attribute :title, Sidereal::Types::String.present
end

DispatchBangNoPayload = Sidereal::Message.define('sidereal_spec.tick')

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

  describe '.dispatch!' do
    let(:store) { Sidereal::Store::Memory.new }

    before { allow(Sidereal).to receive(:store).and_return(store) }

    it 'builds and appends a command from class + payload hash' do
      Sidereal.dispatch!(DispatchBangCmd, title: 'hello')

      claimed = claim_one(store)
      expect(claimed).to be_a(DispatchBangCmd)
      expect(claimed.payload.title).to eq('hello')
    end

    it 'builds and appends a no-payload command from class alone' do
      Sidereal.dispatch!(DispatchBangNoPayload)

      claimed = claim_one(store)
      expect(claimed).to be_a(DispatchBangNoPayload)
    end

    it 'appends a pre-built message instance as-is, preserving id and metadata' do
      original = DispatchBangCmd.new(payload: { title: 'pre-built' }, metadata: { channel: 'ch1' })

      Sidereal.dispatch!(original)

      claimed = claim_one(store)
      expect(claimed.id).to eq(original.id)
      expect(claimed.metadata).to eq({ channel: 'ch1' })
    end

    it 'raises on invalid payload' do
      expect { Sidereal.dispatch!(DispatchBangCmd, title: '') }.to raise_error(Plumb::ParseError)
    end

    it 'raises NoMatchingPatternError on unrecognised arguments' do
      expect { Sidereal.dispatch!('not a class', 'not a hash') }.to raise_error(NoMatchingPatternError)
    end
  end
end

RSpec.describe Sidereal::Configuration do
  subject(:config) { described_class.new }

  it 'defaults workers to 25' do
    expect(config.workers).to eq(25)
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
    custom_store = Class.new do
      def self.append(...) = self
    end

    config.store = custom_store
    expect(config.store).to eq(custom_store)

    invalid_store = Class.new
    expect {
      config.store = invalid_store
    }.to raise_error(Plumb::ParseError)
  end

  it 'allows setting a custom pubsub' do
    custom_pubsub = Class.new do
      def self.start = new
      def self.subscribe(...) = self
      def self.publish(...) = self
    end

    config.pubsub = custom_pubsub
    expect(config.pubsub).to eq(custom_pubsub)

    invalid_pubsub = Class.new
    expect {
      config.pubsub = invalid_pubsub
    }.to raise_error(Plumb::ParseError)
  end

  it 'allows setting a custom dispatcher class' do
    custom_dispatcher = Class.new do
      def self.start = new
    end

    config.dispatcher = custom_dispatcher
    expect(config.dispatcher).to eq(custom_dispatcher)

    invalid_dispatcher = Class.new

    expect {
      config.dispatcher = invalid_dispatcher
    }.to raise_error(Plumb::ParseError)
  end
end
