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

RSpec.describe Sidereal::Commander do
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
      expect { cmdr_class.handle(cmd) }.not_to raise_error
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
      cmdr_class.handle(cmd)
      expect(called_with).to eq(cmd)
    end

    it 'returns a Result with the command' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem
      end

      cmd = TestAddItem.new(payload: { title: 'x' })
      result = cmdr_class.handle(cmd)

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
      result = cmdr_class.handle(cmd)

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
      result = cmdr_class.handle(cmd)

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
      result = cmdr_class.handle(cmd)

      expect(result.events.map(&:class)).to eq([TestItemAdded])
      expect(result.commands.map(&:class)).to eq([TestSendEmail])
    end
  end

  describe '.handle' do
    it 'delegates to a new instance' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
          dispatch TestItemAdded, cmd.payload
        end
      end

      cmd = TestAddItem.new(payload: { title: 'hi' })
      result = cmdr_class.handle(cmd)

      expect(result.msg).to eq(cmd)
      expect(result.events.size).to eq(1)
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
