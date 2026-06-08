# frozen_string_literal: true

require 'tmpdir'

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

  describe '.inject' do
    around { |ex| Sidereal.reset_config!; ex.run; Sidereal.reset_config! }

    it 'is shorthand for config.inject and wires registered deps into a class' do
      Sidereal.config.register(:greeting) { 'hi' }

      klass = Class.new do
        include Sidereal.inject(:greeting)
        def greet = greeting
      end

      expect(klass.new.greet).to eq('hi')          # resolved from Sidereal.config
      expect(klass.new(greeting: 'yo').greet).to eq('yo') # caller override
    end
  end

  describe '.new_host' do
    around { |ex| Sidereal.reset_config!; ex.run; Sidereal.reset_config! }

    it 'freezes config so dependencies cannot be registered after boot' do
      Sidereal.new_host

      expect(Sidereal.config).to be_frozen
      expect { Sidereal.config.register(:late) { 1 } }.to raise_error(FrozenError)
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

  it 'registers and resolves arbitrary app dependencies (IOCContainer)' do
    config.register(:accounts_repo) { :the_repo }
    expect(config[:accounts_repo]).to eq(:the_repo)
  end

  it 'injects registered deps into a class via #inject' do
    config.register(:accounts_repo) { :the_repo }

    container = config
    klass = Class.new do
      include container.inject(:accounts_repo)
      def fetch = accounts_repo
    end

    expect(klass.new.fetch).to eq(:the_repo)
  end

  describe '#use_file_system!' do
    it 'switches store/pubsub/elector to the filesystem + unix-socket impls' do
      Dir.mktmpdir do |dir|
        config.use_file_system!(dir: dir)

        expect(config.store).to be_a(Sidereal::Store::FileSystem)
        expect(config.pubsub).to be_a(Sidereal::PubSub::Unix)
        expect(config.elector).to be_a(Sidereal::Elector::FileSystem)
      end
    end

    it 'returns self for chaining' do
      Dir.mktmpdir do |dir|
        expect(config.use_file_system!(dir: dir)).to be(config)
      end
    end

    it 'lets an individual collaborator be overridden afterward' do
      Dir.mktmpdir do |dir|
        config.use_file_system!(dir: dir)

        custom_store = Class.new { def self.append(...) = self }
        config.store = custom_store

        expect(config.store).to eq(custom_store)        # overridden
        expect(config.pubsub).to be_a(Sidereal::PubSub::Unix)  # left intact
        expect(config.elector).to be_a(Sidereal::Elector::FileSystem)
      end
    end
  end
end
