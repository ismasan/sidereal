# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'tmpdir'
require 'sidereal/pubsub/unix'
require 'sidereal/elector/file_system'

UnixPubSubMsg = Sidereal::Message.define('unix_pubsub_spec.event') do
  attribute :tag, Sidereal::Types::String
end

RSpec.describe Sidereal::PubSub::Unix do
  around(:each) do |example|
    # Use /tmp directly so socket paths fit inside the 104-byte sun_path limit
    # (macOS's default tmpdir under /var/folders/... is too long).
    Dir.mktmpdir(['srl-', ''], '/tmp') do |root|
      @root = root
      example.run
    end
  end

  def build_pubsub(elector: Sidereal::Elector::AlwaysLeader.new, **overrides)
    described_class.new(
      socket_path: File.join(@root, 'pubsub.sock'),
      reconnect_min: 0.01,
      reconnect_max: 0.02,
      elector: elector,
      **overrides
    )
  end

  let(:pubsub) { build_pubsub }

  # Subscribe and start a consumer fiber, then run `body` and stop.
  # Returns the messages delivered.
  def collect_from(pattern, body)
    received = []
    Sync do |task|
      pubsub.start(task)
      channel = pubsub.subscribe(pattern)
      consumer = task.async { channel.start { |m, _| received << m } }
      body.call(pubsub)
      # Allow async fan-out to settle (frame goes over socket → broker → back).
      sleep 0.05
      channel.stop
      consumer.wait
    end
    received
  end

  describe 'exact-match subscription' do
    it 'delivers messages published to the exact channel name' do
      evt = UnixPubSubMsg.new(payload: { tag: 'a' })
      received = collect_from('donations.111', ->(p) { p.publish('donations.111', evt) })
      expect(received.map { |m| m.payload.tag }).to eq(['a'])
    end

    it 'does not deliver messages from other channels' do
      received = collect_from('donations.111', lambda do |p|
        p.publish('donations.222', UnixPubSubMsg.new(payload: { tag: 'b' }))
        p.publish('campaigns.x', UnixPubSubMsg.new(payload: { tag: 'c' }))
      end)
      expect(received).to be_empty
    end
  end

  describe '`*` wildcard subscription' do
    it 'matches exactly one segment' do
      received = collect_from('donations.*', lambda do |p|
        p.publish('donations.111', UnixPubSubMsg.new(payload: { tag: 'a' }))
        p.publish('donations.222', UnixPubSubMsg.new(payload: { tag: 'b' }))
      end)
      expect(received.map { |m| m.payload.tag }).to contain_exactly('a', 'b')
    end

    it 'does not match deeper paths' do
      received = collect_from('donations.*', lambda do |p|
        p.publish('donations.111.created', UnixPubSubMsg.new(payload: { tag: 'a' }))
      end)
      expect(received).to be_empty
    end
  end

  describe '`>` wildcard subscription' do
    it 'matches one or more segments' do
      received = collect_from('donations.>', lambda do |p|
        p.publish('donations.111', UnixPubSubMsg.new(payload: { tag: 'a' }))
        p.publish('donations.222.created', UnixPubSubMsg.new(payload: { tag: 'b' }))
      end)
      expect(received.map { |m| m.payload.tag }).to contain_exactly('a', 'b')
    end

    it 'matches everything when used alone' do
      received = collect_from('>', lambda do |p|
        p.publish('a.b', UnixPubSubMsg.new(payload: { tag: 'a' }))
        p.publish('c.d.e', UnixPubSubMsg.new(payload: { tag: 'b' }))
      end)
      expect(received.map { |m| m.payload.tag }).to contain_exactly('a', 'b')
    end
  end

  describe 'exact + wildcard coexistence' do
    it 'delivers to both subscribers' do
      exact_received = []
      wild_received = []
      Sync do |task|
        pubsub.start(task)
        exact_ch = pubsub.subscribe('donations.111')
        wild_ch = pubsub.subscribe('donations.*')

        ec = task.async { exact_ch.start { |m, _| exact_received << m } }
        wc = task.async { wild_ch.start { |m, _| wild_received << m } }

        pubsub.publish('donations.111', UnixPubSubMsg.new(payload: { tag: 'x' }))
        sleep 0.05
        exact_ch.stop
        wild_ch.stop
        ec.wait
        wc.wait
      end

      expect(exact_received.map { |m| m.payload.tag }).to eq(['x'])
      expect(wild_received.map { |m| m.payload.tag }).to eq(['x'])
    end
  end

  describe '#unsubscribe (via Channel#stop)' do
    it 'removes a subscriber so further publishes skip it' do
      received = []
      Sync do |task|
        pubsub.start(task)
        channel = pubsub.subscribe('donations.*')
        consumer = task.async { channel.start { |m, _| received << m } }

        pubsub.publish('donations.111', UnixPubSubMsg.new(payload: { tag: 'before' }))
        sleep 0.05
        channel.stop
        pubsub.publish('donations.222', UnixPubSubMsg.new(payload: { tag: 'after' }))
        consumer.wait
      end
      expect(received.map { |m| m.payload.tag }).to eq(['before'])
    end
  end

  describe 'subscription / publish validation' do
    it 'rejects an empty pattern' do
      expect { pubsub.subscribe('') }.to raise_error(ArgumentError)
    end

    it 'rejects publishing with wildcards' do
      expect { pubsub.publish('a.*', UnixPubSubMsg.new(payload: { tag: 'x' })) }
        .to raise_error(ArgumentError, /wildcards are not allowed/)
    end
  end

  describe 'in-process loopback determinism' do
    it 'delivers a published message exactly once to a local subscriber' do
      received = []
      Sync do |task|
        pubsub.start(task)
        channel = pubsub.subscribe('donations.111')
        consumer = task.async { channel.start { |m, _| received << m } }

        pubsub.publish('donations.111', UnixPubSubMsg.new(payload: { tag: 'once' }))
        sleep 0.1 # enough for both local + wire paths to settle
        channel.stop
        consumer.wait
      end

      expect(received.size).to eq(1)
    end

    it 'preserves message id and metadata across the round-trip' do
      received = nil
      Sync do |task|
        pubsub.start(task)
        channel = pubsub.subscribe('donations.111')
        consumer = task.async { channel.start { |m, _| received ||= m } }

        original = UnixPubSubMsg.new(payload: { tag: 'roundtrip' }, metadata: { src: 'test' })
        pubsub.publish('donations.111', original)
        sleep 0.05
        channel.stop
        consumer.wait

        # Local delivery is the synchronous path — `received` is the same instance.
        expect(received.id).to eq(original.id)
        expect(received.metadata).to eq(original.metadata)
      end
    end
  end

  describe 'socket path validation' do
    it 'raises when the socket path is too long' do
      long_path = File.join(@root, 'a' * 200, 'pubsub.sock')
      expect do
        described_class.new(socket_path: long_path)
      end.to raise_error(ArgumentError, /too long/)
    end
  end

  describe 'leader election (delegated to injected Elector)' do
    it 'lets exactly one of two pubsubs sharing a lock file become broker' do
      lock_path = File.join(@root, 'pubsub.lock')
      e_a = Sidereal::Elector::FileSystem.new(lock_path: lock_path, retry_interval: 0.05)
      e_b = Sidereal::Elector::FileSystem.new(lock_path: lock_path, retry_interval: 0.05)
      a = build_pubsub(elector: e_a)
      b = build_pubsub(elector: e_b)

      a_is_leader = nil
      b_is_leader = nil

      Sync do |task|
        a.start(task)
        sleep 0.1     # let A acquire the flock and on_promote run
        b.start(task)
        sleep 0.1

        a_is_leader = a.leader?
        b_is_leader = b.leader?

        task.stop
      end

      expect([a_is_leader, b_is_leader]).to contain_exactly(true, false)
    end
  end
end
