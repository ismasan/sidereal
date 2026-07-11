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

  describe '#single_process_subsystems' do
    # Cross-process-safe stand-ins: satisfy the config interfaces but carry no
    # SingleProcess marker (like the Unix pubsub / FileSystem elector+store).
    let(:safe_store)   { double('store', append: nil) }
    let(:safe_pubsub)  { double('pubsub', start: nil, subscribe: nil, publish: nil) }
    let(:safe_elector) { double('elector', start: nil, on_promote: nil, on_demote: nil, leader?: true) }

    it 'lists the in-process defaults (Memory store + pubsub, AlwaysLeader elector)' do
      config = described_class.new # defaults are all in-process
      expect(config.single_process_subsystems).to contain_exactly('store', 'pubsub', 'elector')
    end

    it 'is empty once every subsystem is cross-process safe' do
      config = described_class.new
      config.store = safe_store
      config.pubsub = safe_pubsub
      config.elector = safe_elector
      expect(config.single_process_subsystems).to be_empty
    end

    it 'flags only the subsystems still in-process (e.g. pubsub swapped, elector not)' do
      config = described_class.new
      config.pubsub = safe_pubsub
      expect(config.single_process_subsystems).to contain_exactly('store', 'elector')
    end
  end
end

RSpec.describe 'Sidereal.check_topology!' do
  # Inject a config so the process-global one is never touched.
  let(:in_process_config) { Sidereal::Configuration.new } # all-in-process defaults
  let(:safe_config) do
    Sidereal::Configuration.new.tap do |c|
      c.store = double('store', append: nil)
      c.pubsub = double('pubsub', start: nil, subscribe: nil, publish: nil)
      c.elector = double('elector', start: nil, on_promote: nil, on_demote: nil, leader?: true)
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

  it 'does nothing when every subsystem is cross-process safe' do
    expect(Console).not_to receive(:error)
    expect { Sidereal.check_topology!(8, config: safe_config) }.not_to raise_error
  end
end
