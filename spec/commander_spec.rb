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

TestNotification = Sidereal::Message.define('test.notification') do
  attribute :text, Sidereal::Types::String
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

    it 'exposes registered classes via .handled_commands' do
      cmdr = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
        end
        command TestSendEmail do |cmd|
        end
      end

      expect(cmdr.handled_commands).to contain_exactly(TestAddItem, TestSendEmail)
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
      expect { cmdr_class.handle(cmd, pubsub: pubsub) }.not_to raise_error
    end
  end

  describe '.from' do
    let(:cmdr_class) do
      Class.new(Sidereal::Commander) do
        command TestAddItem
      end
    end

    it 'instantiates a registered command from a hash' do
      cmd = cmdr_class.from(type: 'test.add_item', payload: { title: 'hello' })
      expect(cmd).to be_a(TestAddItem)
      expect(cmd.payload.title).to eq('hello')
    end

    it 'raises for unregistered types' do
      expect {
        cmdr_class.from(type: 'test.unknown', payload: {})
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
      cmdr_class.handle(cmd, pubsub: pubsub)
      expect(called_with).to eq(cmd)
    end

    it 'returns a Result with the command' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem
      end

      cmd = TestAddItem.new(payload: { title: 'x' })
      result = cmdr_class.handle(cmd, pubsub: pubsub)

      expect(result).to be_a(Sidereal::Commander::Result)
      expect(result.msg).to eq(cmd)
    end

    it 'returns dispatched events with correlation in the Result' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
          dispatch TestItemAdded, cmd.payload
        end
      end

      cmd = TestAddItem.new(payload: { title: 'hello' })
      result = cmdr_class.handle(cmd, pubsub: pubsub)

      expect(result.events.size).to eq(1)
      evt = result.events.first
      expect(evt).to be_a(TestItemAdded)
      expect(evt.payload.title).to eq('hello')
      expect(evt.causation_id).to eq(cmd.id)
      expect(evt.correlation_id).to eq(cmd.correlation_id)
    end

    it 'returns dispatched commands in the Result' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
          dispatch TestSendEmail, to: 'user@example.com'
        end
        command TestSendEmail
      end

      cmd = TestAddItem.new(payload: { title: 'x' })
      result = cmdr_class.handle(cmd, pubsub: pubsub)

      expect(result.commands.size).to eq(1)
      expect(result.commands.first).to be_a(TestSendEmail)
      expect(result.commands.first.payload.to).to eq('user@example.com')
    end

    it 'separates events from commands in the Result' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
          dispatch TestItemAdded, cmd.payload
          dispatch TestSendEmail, to: 'user@example.com'
        end
        command TestSendEmail
      end

      cmd = TestAddItem.new(payload: { title: 'x' })
      result = cmdr_class.handle(cmd, pubsub: pubsub)

      expect(result.events.map(&:class)).to eq([TestItemAdded])
      expect(result.commands.map(&:class)).to eq([TestSendEmail])
    end

    it 'propagates handler exceptions to the caller' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
          raise 'boom'
        end
      end

      cmd = TestAddItem.new(payload: { title: 'x' })
      expect { cmdr_class.handle(cmd, pubsub: pubsub) }.to raise_error('boom')
    end
  end

  describe '.on_error' do
    it 're-raises by default' do
      ex = RuntimeError.new('default')
      expect { Sidereal::Commander.on_error(ex) }.to raise_error('default')
    end

    it 'is overridable on a subclass' do
      handled = []
      cmdr_class = Class.new(Sidereal::Commander) do
        define_singleton_method(:on_error) { |ex| handled << ex }
      end

      ex = RuntimeError.new('swallowed')
      expect { cmdr_class.on_error(ex) }.not_to raise_error
      expect(handled).to eq([ex])
    end
  end

  describe '.handle' do
    it 'delegates to a new instance with pubsub' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
          dispatch TestItemAdded, cmd.payload
        end
      end

      cmd = TestAddItem.new(payload: { title: 'hi' })
      result = cmdr_class.handle(cmd, pubsub: pubsub)

      expect(result.msg).to eq(cmd)
      expect(result.events.size).to eq(1)
    end
  end

  describe '#broadcast' do
    it 'publishes directly to pubsub during handling' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
          broadcast TestNotification, text: 'hello'
        end
      end

      cmd = TestAddItem.new(payload: { title: 'x' })
      cmd = cmd.with_metadata(channel: 'test-ch')
      cmdr_class.handle(cmd, pubsub: pubsub)

      expect(pubsub.published.size).to eq(1)
      pub = pubsub.published.first
      expect(pub[:channel]).to eq('test-ch')
      expect(pub[:message]).to be_a(TestNotification)
      expect(pub[:message].payload.text).to eq('hello')
    end

    it 'correlates broadcast messages to the source command' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
          broadcast TestNotification, text: 'hey'
        end
      end

      cmd = TestAddItem.new(payload: { title: 'x' })
      cmd = cmd.with_metadata(channel: 'ch')
      cmdr_class.handle(cmd, pubsub: pubsub)

      msg = pubsub.published.first[:message]
      expect(msg.causation_id).to eq(cmd.id)
      expect(msg.correlation_id).to eq(cmd.correlation_id)
    end

    it 'does not include broadcast messages in the Result' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
          broadcast TestNotification, text: 'transient'
          dispatch TestItemAdded, cmd.payload
        end
      end

      cmd = TestAddItem.new(payload: { title: 'x' })
      cmd = cmd.with_metadata(channel: 'ch')
      result = cmdr_class.handle(cmd, pubsub: pubsub)

      expect(result.events.size).to eq(1)
      expect(result.events.first).to be_a(TestItemAdded)
      expect(pubsub.published.size).to eq(1)
      expect(pubsub.published.first[:message]).to be_a(TestNotification)
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
