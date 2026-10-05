# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'sidereal/integrations/file_system'

RSpec.describe Sidereal::Integrations::FileSystem do
  let(:config) { Sidereal.config }

  describe '.setup' do
    it 'implements the store/pubsub/elector with the filesystem + unix-socket impls' do
      Dir.mktmpdir do |dir|
        described_class.setup(config, dir: dir)
        config.build!

        expect(config['sidereal.store']).to be_a(Sidereal::Store::FileSystem)
        expect(config['sidereal.pubsub']).to be_a(Sidereal::PubSub::Unix)
        expect(config['sidereal.elector']).to be_a(Sidereal::Elector::FileSystem)
      end
    end

    it 'places files, socket, and lock under dir' do
      Dir.mktmpdir do |dir|
        described_class.setup(config, dir: dir)
        config.build!

        # Appending a command creates the store tree under <dir>/store.
        config['sidereal.store'].append(Sidereal::Message.define('intg_fs.ping').new)

        expect(Dir.exist?(File.join(dir, 'store'))).to be true
      end
    end

    it 'defaults dir to ./storage' do
      elector = double('elector', start: nil, on_promote: nil, on_demote: nil, leader?: true)
      expect(Sidereal::Store::FileSystem).to receive(:new)
        .with(root: File.join('storage', 'store'))
        .and_return(double('store', append: nil))
      expect(Sidereal::PubSub::Unix).to receive(:new)
        .with(socket_path: File.join('storage', 'pubsub.sock'), elector:)
        .and_return(double('pubsub', start: nil, subscribe: nil, publish: nil))
      expect(Sidereal::Elector::FileSystem).to receive(:new)
        .with(lock_path: File.join('storage', 'leader.lock'))
        .and_return(elector)

      described_class.setup(config)
      config.build!
    end

    it 'builds nothing until the config is built' do
      expect(Sidereal::Store::FileSystem).not_to receive(:new)
      expect(Sidereal::PubSub::Unix).not_to receive(:new)
      expect(Sidereal::Elector::FileSystem).not_to receive(:new)

      described_class.setup(config)
    end

    it 'hands the pubsub whichever elector implements sidereal.elector, including a later one' do
      Dir.mktmpdir do |dir|
        described_class.setup(config, dir: dir)
        elector = Sidereal::Elector::AlwaysLeader.new
        config.config!('sidereal.elector') { elector }
        config.build!

        expect(config['sidereal.pubsub']).to be_leader
        expect(config['sidereal.elector']).to be(elector)
      end
    end

    it 'starts the elector and the pubsub with the config, elector first' do
      Dir.mktmpdir do |dir|
        described_class.setup(config, dir: dir)
        order = config.prepare!.ordered_nodes.map(&:path)

        expect(order.index('sidereal.elector')).to be < order.index('sidereal.pubsub')

        Sync do |task|
          config.start!(task)
          expect(config['sidereal.elector']).to be_leader
          expect(config['sidereal.pubsub']).to be_leader
        ensure
          config.teardown!
          task.children.each(&:stop)
        end
      end
    end

    it 'returns the config' do
      Dir.mktmpdir do |dir|
        expect(described_class.setup(config, dir: dir)).to be(config)
      end
    end
  end
end
