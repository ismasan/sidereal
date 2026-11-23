# frozen_string_literal: true

require 'spec_helper'
require 'async'

PubSubMsg = Sidereal::Message.define('pubsub_spec.event')

RSpec.describe Sidereal::PubSub::Memory do
  let(:pubsub) { described_class.new }

  # Subscribe to `pattern` (or an Array of patterns), publish each (channel_name, event) pair in `publishes`,
  # then stop. Returns the list of messages delivered to the subscription.
  def collect_from(pattern, publishes)
    received = []

    Sync do |task|
      channel = pubsub.subscribe(*Array(pattern))

      consumer = task.async do
        channel.start do |msg, _ch|
          received << msg
        end
      end

      publishes.each { |ch_name, evt| pubsub.publish(ch_name, evt) }
      channel.stop
      consumer.wait
    end

    received
  end

  describe 'exact-match subscription' do
    it 'delivers messages published to the exact channel name' do
      evt = PubSubMsg.new
      received = collect_from('donations.111', [['donations.111', evt]])

      expect(received).to eq([evt])
    end

    it 'does not deliver messages from other channels' do
      evt = PubSubMsg.new
      received = collect_from('donations.111', [
        ['donations.222', evt],
        ['campaigns.x', evt]
      ])

      expect(received).to be_empty
    end
  end

  describe '`*` wildcard subscription' do
    it 'matches exactly one segment' do
      a = PubSubMsg.new
      b = PubSubMsg.new
      received = collect_from('donations.*', [
        ['donations.111', a],
        ['donations.222', b]
      ])

      expect(received).to contain_exactly(a, b)
    end

    it 'does not match deeper paths' do
      evt = PubSubMsg.new
      received = collect_from('donations.*', [['donations.111.created', evt]])

      expect(received).to be_empty
    end

    it 'does not match shorter paths' do
      evt = PubSubMsg.new
      received = collect_from('donations.*', [['donations', evt]])

      expect(received).to be_empty
    end

    it 'matches mid-pattern wildcards' do
      a = PubSubMsg.new
      b = PubSubMsg.new
      received = collect_from('donations.*.created', [
        ['donations.111.created', a],
        ['donations.222.created', b],
        ['donations.333.updated', PubSubMsg.new]
      ])

      expect(received).to contain_exactly(a, b)
    end
  end

  describe '`>` wildcard subscription' do
    it 'matches one segment' do
      evt = PubSubMsg.new
      received = collect_from('donations.>', [['donations.111', evt]])

      expect(received).to eq([evt])
    end

    it 'matches multiple segments' do
      evt = PubSubMsg.new
      received = collect_from('donations.>', [['donations.222.created', evt]])

      expect(received).to eq([evt])
    end

    it 'does not match the bare prefix' do
      evt = PubSubMsg.new
      received = collect_from('donations.>', [['donations', evt]])

      expect(received).to be_empty
    end

    it 'does not match a different root' do
      evt = PubSubMsg.new
      received = collect_from('donations.>', [['campaigns.x', evt]])

      expect(received).to be_empty
    end

    it 'matches everything when used alone' do
      a = PubSubMsg.new
      b = PubSubMsg.new
      received = collect_from('>', [
        ['donations.111', a],
        ['campaigns.x.y', b]
      ])

      expect(received).to contain_exactly(a, b)
    end
  end

  describe 'exact + wildcard coexistence' do
    it 'delivers to both exact and wildcard subscribers' do
      evt = PubSubMsg.new
      exact_received = []
      wild_received = []

      Sync do |task|
        exact_ch = pubsub.subscribe('donations.111')
        wild_ch = pubsub.subscribe('donations.*')

        exact_consumer = task.async { exact_ch.start { |m, _| exact_received << m } }
        wild_consumer = task.async { wild_ch.start { |m, _| wild_received << m } }

        pubsub.publish('donations.111', evt)
        exact_ch.stop
        wild_ch.stop
        exact_consumer.wait
        wild_consumer.wait
      end

      expect(exact_received).to eq([evt])
      expect(wild_received).to eq([evt])
    end
  end

  describe 'multiple wildcard subscribers' do
    it 'delivers a separate copy to each matching subscriber' do
      evt = PubSubMsg.new
      a_received = []
      b_received = []

      Sync do |task|
        a = pubsub.subscribe('donations.>')
        b = pubsub.subscribe('donations.*')

        a_consumer = task.async { a.start { |m, _| a_received << m } }
        b_consumer = task.async { b.start { |m, _| b_received << m } }

        pubsub.publish('donations.111', evt)
        a.stop
        b.stop
        a_consumer.wait
        b_consumer.wait
      end

      expect(a_received).to eq([evt])
      expect(b_received).to eq([evt])
    end
  end

  describe 'subscription to several patterns' do
    it 'delivers messages matching any of them on one channel, in publish order' do
      a = PubSubMsg.new
      b = PubSubMsg.new
      c = PubSubMsg.new
      received = collect_from(['orders.>', 'system'], [['orders.1', a], ['system', b], ['campaigns.1', c]])

      expect(received).to eq([a, b])
    end

    it 'delivers a message matching several of them once' do
      evt = PubSubMsg.new
      received = collect_from(['orders.>', 'orders.*', 'orders.1'], [['orders.1', evt]])

      expect(received).to eq([evt])
    end

    it 'ignores a repeated pattern' do
      evt = PubSubMsg.new
      received = collect_from(['orders.1', 'orders.1'], [['orders.1', evt]])

      expect(received).to eq([evt])
    end

    it 'stops delivery on every pattern when the channel stops' do
      before_stop = PubSubMsg.new
      received = []

      Sync do |task|
        channel = pubsub.subscribe('orders.1', 'system.>')
        consumer = task.async { channel.start { |m, _| received << m } }

        pubsub.publish('orders.1', before_stop)
        channel.stop
        pubsub.publish('orders.1', PubSubMsg.new)
        pubsub.publish('system.x', PubSubMsg.new)
        consumer.wait
      end

      expect(received).to eq([before_stop])
    end

    it 'leaves other channels on the same patterns subscribed' do
      evt = PubSubMsg.new
      received = []

      Sync do |task|
        stopped = pubsub.subscribe('orders.1', 'system.>')
        other = pubsub.subscribe('orders.1', 'system.>')
        consumer = task.async { other.start { |m, _| received << m } }

        stopped.stop
        pubsub.publish('orders.1', evt)
        other.stop
        consumer.wait
      end

      expect(received).to eq([evt])
    end

    it 'exposes the patterns it is subscribed to' do
      expect(pubsub.subscribe('orders.1', 'system').patterns).to eq(['orders.1', 'system'])
    end

    it 'requires at least one pattern' do
      expect { pubsub.subscribe }.to raise_error(ArgumentError, /at least one/)
    end

    it 'validates every pattern' do
      expect { pubsub.subscribe('orders.1', 'bad..x') }.to raise_error(ArgumentError, /empty segment/)
    end
  end

  describe '#unsubscribe' do
    it 'removes a wildcard subscriber so further publishes skip it' do
      evt_before = PubSubMsg.new
      evt_after = PubSubMsg.new
      received = []

      Sync do |task|
        channel = pubsub.subscribe('donations.*')

        consumer = task.async { channel.start { |m, _| received << m } }

        pubsub.publish('donations.111', evt_before)
        channel.stop
        pubsub.publish('donations.222', evt_after)
        consumer.wait
      end

      expect(received).to eq([evt_before])
    end
  end

  describe 'subscription validation' do
    it 'rejects empty pattern' do
      expect { pubsub.subscribe('') }.to raise_error(ArgumentError)
    end

    it 'rejects empty segments' do
      expect { pubsub.subscribe('donations..x') }.to raise_error(ArgumentError, /empty segment/)
      expect { pubsub.subscribe('donations.') }.to raise_error(ArgumentError, /empty segment/)
      expect { pubsub.subscribe('.donations') }.to raise_error(ArgumentError, /empty segment/)
    end

    it 'rejects `>` in non-trailing position' do
      expect { pubsub.subscribe('donations.>.created') }
        .to raise_error(ArgumentError, /`>` wildcard must be the last segment/)
    end
  end

  describe 'publish validation' do
    it 'rejects empty channel name' do
      expect { pubsub.publish('', PubSubMsg.new) }.to raise_error(ArgumentError)
    end

    it 'rejects empty segments' do
      expect { pubsub.publish('donations..x', PubSubMsg.new) }
        .to raise_error(ArgumentError, /empty segment/)
    end

    it 'rejects wildcard characters' do
      expect { pubsub.publish('donations.*', PubSubMsg.new) }
        .to raise_error(ArgumentError, /wildcards are not allowed/)
      expect { pubsub.publish('donations.>', PubSubMsg.new) }
        .to raise_error(ArgumentError, /wildcards are not allowed/)
    end
  end

  describe 'publishing with no subscribers' do
    it 'is a no-op' do
      expect { pubsub.publish('donations.111', PubSubMsg.new) }.not_to raise_error
    end
  end
end
