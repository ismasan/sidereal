# frozen_string_literal: true

require 'spec_helper'

# -- Test messages --

TestAddItem = Sidereal::Message.define('test.add_item') do
  attribute :title, Sidereal::Types::String.present
end

TestItemAdded = Sidereal::Message.define('test.item_added') do
  attribute :title, Sidereal::Types::String
end

TestSendEmail = Sidereal::Message.define('test.send_email') do
  attribute :to, Sidereal::Types::String
end

# -- Fake pubsub --

class FakePubSub
  attr_reader :published

  def initialize
    @published = []
  end

  def publish(channel, message)
    @published << { channel: channel, message: message }
  end
end

RSpec.describe Sidereal::Commander do
  let(:pubsub) { FakePubSub.new }

  describe '.command' do
    it 'registers a message class in the command registry' do
      cmdr = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
        end
      end

      expect(cmdr.command_registry).to have_key('test.add_item')
      expect(cmdr.command_registry['test.add_item']).to eq(TestAddItem)
    end

    it 'raises for non-Message classes' do
      expect {
        Class.new(Sidereal::Commander) do
          command String
        end
      }.to raise_error(ArgumentError)
    end

    it 'provides a default no-op handler when no block is given' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem
      end

      cmd = TestAddItem.new(payload: { title: 'test' })
      cmd = cmd.with_metadata(channel: 'ch')
      cmdr = cmdr_class.new(pubsub: pubsub)
      expect { cmdr.handle(cmd) }.not_to raise_error
    end
  end

  describe '#from' do
    let(:cmdr_class) do
      Class.new(Sidereal::Commander) do
        command TestAddItem
      end
    end

    it 'instantiates a registered command from a hash' do
      cmdr = cmdr_class.new(pubsub: pubsub)
      cmd = cmdr.from(type: 'test.add_item', payload: { title: 'hello' })
      expect(cmd).to be_a(TestAddItem)
      expect(cmd.payload.title).to eq('hello')
    end

    it 'raises for unregistered types' do
      cmdr = cmdr_class.new(pubsub: pubsub)
      expect {
        cmdr.from(type: 'test.unknown', payload: {})
      }.to raise_error(KeyError)
    end
  end

  describe '#handle' do
    it 'calls the registered handler block' do
      called_with = nil
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
          called_with = cmd
        end
      end

      cmd = TestAddItem.new(payload: { title: 'buy milk' })
      cmd = cmd.with_metadata(channel: 'ch')
      cmdr_class.new(pubsub: pubsub).handle(cmd)
      expect(called_with).to eq(cmd)
    end

    it 'publishes the command itself on its channel' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem
      end

      cmd = TestAddItem.new(payload: { title: 'x' })
      cmd = cmd.with_metadata(channel: 'test-ch')
      cmdr_class.new(pubsub: pubsub).handle(cmd)

      cmd_pub = pubsub.published.find { |p| p[:message].is_a?(TestAddItem) }
      expect(cmd_pub).not_to be_nil
      expect(cmd_pub[:channel]).to eq('test-ch')
    end

    it 'publishes dispatched events with correlation' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
          dispatch TestItemAdded, cmd.payload
        end
      end

      cmd = TestAddItem.new(payload: { title: 'hello' })
      cmd = cmd.with_metadata(channel: 'ch')
      cmdr_class.new(pubsub: pubsub).handle(cmd)

      evt_pub = pubsub.published.find { |p| p[:message].is_a?(TestItemAdded) }
      expect(evt_pub).not_to be_nil
      expect(evt_pub[:channel]).to eq('ch')
      evt = evt_pub[:message]
      expect(evt.payload.title).to eq('hello')
      expect(evt.causation_id).to eq(cmd.id)
      expect(evt.correlation_id).to eq(cmd.correlation_id)
    end

    it 'publishes dispatched events before the command' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
          dispatch TestItemAdded, cmd.payload
        end
      end

      cmd = TestAddItem.new(payload: { title: 'x' })
      cmd = cmd.with_metadata(channel: 'ch')
      cmdr_class.new(pubsub: pubsub).handle(cmd)

      types = pubsub.published.map { |p| p[:message].class }
      expect(types).to eq([TestItemAdded, TestAddItem])
    end
  end

  describe 'subclass isolation' do
    it 'does not share registries between commander subclasses' do
      cmdr_a = Class.new(Sidereal::Commander) { command TestAddItem }
      cmdr_b = Class.new(Sidereal::Commander) { command TestSendEmail }

      expect(cmdr_a.command_registry.keys).to eq(['test.add_item'])
      expect(cmdr_b.command_registry.keys).to eq(['test.send_email'])
    end
  end
end
