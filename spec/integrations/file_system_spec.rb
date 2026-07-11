# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'sidereal/integrations/file_system'

RSpec.describe Sidereal::Integrations::FileSystem do
  let(:config) { Sidereal::Configuration.new }

  describe '.setup' do
    it 'wires the store/pubsub/elector to the filesystem + unix-socket impls' do
      Dir.mktmpdir do |dir|
        described_class.setup(config, dir: dir)

        expect(config.store).to be_a(Sidereal::Store::FileSystem)
        expect(config.pubsub).to be_a(Sidereal::PubSub::Unix)
        expect(config.elector).to be_a(Sidereal::Elector::FileSystem)
      end
    end

    it 'places files, socket, and lock under dir' do
      Dir.mktmpdir do |dir|
        described_class.setup(config, dir: dir)

        # Appending a command creates the store tree under <dir>/store.
        config.store.append(Sidereal::Message.define('intg_fs.ping').new)

        expect(Dir.exist?(File.join(dir, 'store'))).to be true
      end
    end

    it 'defaults dir to ./storage' do
      expect(Sidereal::Store::FileSystem).to receive(:new)
        .with(root: File.join('storage', 'store'))
        .and_return(double('store', append: nil))
      expect(Sidereal::PubSub::Unix).to receive(:new)
        .with(socket_path: File.join('storage', 'pubsub.sock'))
        .and_return(double('pubsub', start: nil, subscribe: nil, publish: nil))
      expect(Sidereal::Elector::FileSystem).to receive(:new)
        .with(lock_path: File.join('storage', 'leader.lock'))
        .and_return(double('elector', start: nil, on_promote: nil, on_demote: nil, leader?: true))

      described_class.setup(config)
    end

    it 'returns the config' do
      Dir.mktmpdir do |dir|
        expect(described_class.setup(config, dir: dir)).to be(config)
      end
    end
  end

  describe 'applied via Configuration#use' do
    it 'wires the collaborators and returns self' do
      Dir.mktmpdir do |dir|
        result = config.use(described_class, dir: dir)

        expect(result).to be(config)
        expect(config.store).to be_a(Sidereal::Store::FileSystem)
        expect(config.pubsub).to be_a(Sidereal::PubSub::Unix)
        expect(config.elector).to be_a(Sidereal::Elector::FileSystem)
      end
    end
  end
end
