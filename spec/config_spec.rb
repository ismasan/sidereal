# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Sidereal::Config do
  subject(:config) { described_class.build }

  describe '.build' do
    before { config.build! }

    it 'defaults the store, pubsub and elector to the in-process implementations' do
      expect(config['store']).to be(Sidereal::Store::Memory.instance)
      expect(config['pubsub']).to be(Sidereal::PubSub::Memory.instance)
      expect(config['elector']).to be_a(Sidereal::Elector::AlwaysLeader)
    end

    it 'defaults workers.count to 25, and runner.process to :all' do
      expect(config['workers.count']).to eq(25)
      expect(config['runner.process']).to eq(:all)
    end

    it 'holds the process-global registries' do
      expect(config['channels']).to be(Sidereal.channels)
      expect(config['exceptions']).to be(Sidereal.exceptions)
      expect(config['scheduler']).to be(Sidereal.scheduler)
    end

    it 'builds a Sidereal::Dispatcher and a runner for it' do
      expect(config['dispatcher']).to be_a(Sidereal::Dispatcher)
      expect(config['runner']).to be_a(Sidereal::DispatcherRunner)
    end

    it 'orders the components so the elector starts before the pubsub, and the dispatcher after what it uses' do
      order = config.ordered_nodes.map(&:key)

      expect(order.index('elector')).to be < order.index('pubsub')
      %w[store pubsub channels exceptions].each do |dep|
        expect(order.index(dep)).to be < order.index('dispatcher')
      end
      expect(order.index('elector')).to be < order.index('runner')
      expect(order.index('runner')).to be < order.index('scheduler')
    end

    it "defers the dispatcher, which the runner starts by key" do
      expect(config.node('dispatcher')).to be_deferred
      expect(config['runner.targets']).to eq(['dispatcher'])
    end
  end

  describe 'types' do
    it 'refuses a store without #append' do
      config.config!('store') { Object.new }

      expect { config.build! }.to raise_error(Plumb::ParseError, /store/)
    end

    it 'refuses a runner.process other than :all or :leader' do
      config.config!('runner.process') { :some }

      expect { config.build! }.to raise_error(Plumb::ParseError, /runner\.process/)
    end
  end

  describe 'lifecycle' do
    it 'locks the registries on start, not on build' do
      config.build!
      expect(Sidereal.channels).not_to be_locked
      expect(Sidereal.exceptions).not_to be_locked

      Sync do |task|
        config.start!(task)
        expect(Sidereal.channels).to be_locked
        expect(Sidereal.exceptions).to be_locked
      ensure
        config.teardown!
      end
    end

    it 'starts the dispatcher, and stops it on teardown' do
      Sync do |task|
        config.config!('workers.count') { 1 }
        config.start!(task)
        expect(config['runner']).to be_running
        expect(config.node('dispatcher').status).to eq(:started)

        config.teardown!
        expect(config['runner']).not_to be_running
        expect(config.node('dispatcher').status).to eq(:torn_down)
      end
    end
  end
end

RSpec.describe Sidereal do
  describe '.config' do
    it 'mounts Sidereal.component under sidereal' do
      expect(Sidereal.config.node('sidereal')).to be(Sidereal.component)
    end

    it 'reads Sidereal.store, .pubsub and .elector from it, once built' do
      expect { Sidereal.store }.to raise_error(Sourced::Component::NotBuiltError)

      store = double('store', append: nil)
      Sidereal.config.config!('sidereal.store') { store }
      Sidereal.config.build!

      expect(Sidereal.store).to be(store)
      expect(Sidereal.pubsub).to be(Sidereal.config['sidereal.pubsub'])
      expect(Sidereal.elector).to be(Sidereal.config['sidereal.elector'])
    end

    it 'is replaced by reset_config!, along with Sidereal.component' do
      config = Sidereal.config
      component = Sidereal.component
      Sidereal.reset_config!

      expect(Sidereal.config).not_to be(config)
      expect(Sidereal.component).not_to be(component)
      expect(Sidereal.config.node('sidereal')).to be(Sidereal.component)
    end
  end

  describe '.use' do
    it 'applies an integration via #setup(config, **opts) and returns the config' do
      received = nil
      integration = Object.new
      integration.define_singleton_method(:setup) do |config, **opts|
        received = [config, opts]
        config
      end

      expect(Sidereal.use(integration, foo: 1, bar: 2)).to be(Sidereal.config)
      expect(received).to eq([Sidereal.config, { foo: 1, bar: 2 }])
    end

    it 'raises for an object that does not respond to #setup' do
      expect { Sidereal.use(Object.new) }.to raise_error(Plumb::ParseError)
    end
  end

  describe '.use_file_system!' do
    it 'switches store/pubsub/elector to the filesystem + unix-socket impls' do
      Dir.mktmpdir do |dir|
        expect(Sidereal.use_file_system!(dir:)).to be(Sidereal.config)
        Sidereal.config.build!

        expect(Sidereal.store).to be_a(Sidereal::Store::FileSystem)
        expect(Sidereal.pubsub).to be_a(Sidereal::PubSub::Unix)
        expect(Sidereal.elector).to be_a(Sidereal::Elector::FileSystem)
      end
    end

    it 'lets an individual component be re-implemented afterward' do
      Dir.mktmpdir do |dir|
        Sidereal.use_file_system!(dir:)
        custom_store = Class.new { def self.append(...) = self }
        Sidereal.config.config!('sidereal.store') { custom_store }
        Sidereal.config.build!

        expect(Sidereal.store).to be(custom_store)
        expect(Sidereal.pubsub).to be_a(Sidereal::PubSub::Unix)
        expect(Sidereal.elector).to be_a(Sidereal::Elector::FileSystem)
      end
    end
  end

  describe '.lock!' do
    it 'makes a build in the given process raise ForkError' do
      Sidereal.lock!(Process.pid)

      expect { Sidereal.config.build! }.to raise_error(Sidereal::ForkError, /#{Process.pid}/)
    end

    it 'leaves builds in other processes alone' do
      Sidereal.lock!(Process.pid + 1)

      expect { Sidereal.config.build! }.not_to raise_error
    end
  end

  describe '.single_process_subsystems' do
    # Cross-process-safe stand-ins: satisfy the interfaces but carry no
    # SingleProcess marker (like the Unix pubsub / FileSystem elector+store).
    let(:safe_store)   { double('store', append: nil) }
    let(:safe_pubsub)  { double('pubsub', start: nil, subscribe: nil, publish: nil) }
    let(:safe_elector) { double('elector', start: nil, on_promote: nil, on_demote: nil, leader?: true) }

    it 'lists the in-process defaults (Memory store + pubsub, AlwaysLeader elector)' do
      Sidereal.config.build!
      expect(Sidereal.single_process_subsystems).to contain_exactly('store', 'pubsub', 'elector')
    end

    it 'is empty once every subsystem is cross-process safe' do
      Sidereal.config.config!('sidereal.store') { safe_store }
      Sidereal.config.config!('sidereal.pubsub') { safe_pubsub }
      Sidereal.config.config!('sidereal.elector') { safe_elector }
      Sidereal.config.build!
      expect(Sidereal.single_process_subsystems).to be_empty
    end

    it 'flags only the subsystems still in-process (e.g. pubsub swapped, elector not)' do
      Sidereal.config.config!('sidereal.pubsub') { safe_pubsub }
      Sidereal.config.build!
      expect(Sidereal.single_process_subsystems).to contain_exactly('store', 'elector')
    end
  end

  describe '.check_topology!' do
    # Inject a config so the process-global one is never touched.
    let(:in_process_config) do
      Sourced::Component.new.tap { |root| root.mount('sidereal', Sidereal::Config.build) }
    end
    let(:safe_config) do
      in_process_config.tap do |c|
        c.config!('sidereal.store') { double('store', append: nil) }
        c.config!('sidereal.pubsub') { double('pubsub', start: nil, subscribe: nil, publish: nil) }
        c.config!('sidereal.elector') { double('elector', start: nil, on_promote: nil, on_demote: nil, leader?: true) }
      end
    end

    it 'returns without erroring or exiting for a single worker' do
      expect(Console).not_to receive(:error)
      expect { Sidereal.check_topology!(1, config: in_process_config) }.not_to raise_error
    end

    it 'logs a loud multi-line error and exits when in-process subsystems meet multiple workers' do
      expect(Console).to receive(:error) do |_source, message, **meta|
        expect(message).to include('Refusing to boot')
        expect(message).to include('use_file_system!')
        expect(message.lines.size).to be > 1                 # multi-line description
        expect(meta[:subsystems]).to contain_exactly('store', 'pubsub', 'elector')
        expect(meta[:process_count]).to eq(3)
      end
      expect { Sidereal.check_topology!(3, config: in_process_config) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it 'builds the config to inspect it' do
      Sidereal.check_topology!(8, config: safe_config)

      expect(safe_config.boot_status).to eq(:built)
    end

    it 'does nothing when every subsystem is cross-process safe' do
      expect(Console).not_to receive(:error)
      expect { Sidereal.check_topology!(8, config: safe_config) }.not_to raise_error
    end
  end
end
