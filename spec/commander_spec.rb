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

    describe 'scheduling dispatched messages' do
      it 'schedules a dispatched command via .at' do
        future = Time.now + 10
        cmdr_class = Class.new(Sidereal::Commander) do
          command TestAddItem do |_cmd|
            dispatch(TestSendEmail, to: 'user@example.com').at(future)
          end
          command TestSendEmail
        end

        cmd = TestAddItem.new(payload: { title: 'x' })
        result = cmdr_class.handle(cmd, pubsub: pubsub)

        expect(result.commands.size).to eq(1)
        expect(result.commands.first).to be_a(TestSendEmail)
        expect(result.commands.first.created_at).to be_within(0.001).of(future)
      end

      it 'schedules a dispatched event via .at' do
        future = Time.now + 30
        cmdr_class = Class.new(Sidereal::Commander) do
          command TestAddItem do |cmd|
            dispatch(TestItemAdded, title: cmd.payload.title).at(future)
          end
        end

        cmd = TestAddItem.new(payload: { title: 'x' })
        result = cmdr_class.handle(cmd, pubsub: pubsub)

        expect(result.events.first.created_at).to be_within(0.001).of(future)
      end

      it 'supports .in(seconds) as relative scheduling sugar' do
        before = Time.now
        cmdr_class = Class.new(Sidereal::Commander) do
          command TestAddItem do |_cmd|
            dispatch(TestSendEmail, to: 'a@b.com').in(60)
          end
          command TestSendEmail
        end

        cmd = TestAddItem.new(payload: { title: 'x' })
        result = cmdr_class.handle(cmd, pubsub: pubsub)

        expect(result.commands.first.created_at).to be_within(0.5).of(before + 60)
      end

      it 'preserves correlation when scheduling' do
        cmdr_class = Class.new(Sidereal::Commander) do
          command TestAddItem do |_cmd|
            dispatch(TestSendEmail, to: 'x@y.com').at(Time.now + 5)
          end
          command TestSendEmail
        end

        cmd = TestAddItem.new(payload: { title: 'x' })
        result = cmdr_class.handle(cmd, pubsub: pubsub)

        scheduled = result.commands.first
        expect(scheduled.causation_id).to eq(cmd.id)
        expect(scheduled.correlation_id).to eq(cmd.correlation_id)
      end
    end
  end

  describe '.channel_name' do
    it "defaults to 'system'" do
      msg = TestAddItem.new(payload: { title: 'x' })
      expect(Sidereal::Commander.channel_name(msg)).to eq('system')
    end

    it 'is overridable on a subclass' do
      cmdr = Class.new(Sidereal::Commander) do
        def self.channel_name(msg) = "items.#{msg.payload.title}"
      end

      msg = TestAddItem.new(payload: { title: '42' })
      expect(cmdr.channel_name(msg)).to eq('items.42')
    end
  end

  describe '.on_error' do
    let(:msg) { TestAddItem.new(payload: { name: 'x' }) }

    def meta_for(attempt)
      Sidereal::Store::Meta.new(attempt: attempt, first_appended_at: Time.now)
    end

    it 'returns Result::Retry on attempts 1..4 by default' do
      ex = RuntimeError.new('boom')

      (1..4).each do |attempt|
        result = Sidereal::Commander.on_error(ex, msg, meta_for(attempt))
        expect(result).to be_a(Sidereal::Store::Result::Retry)
      end
    end

    it 'schedules retry with 2**attempt-second backoff' do
      ex = RuntimeError.new('boom')

      [1, 2, 3, 4].each do |attempt|
        before = Time.now
        result = Sidereal::Commander.on_error(ex, msg, meta_for(attempt))
        after = Time.now

        expect(result.at).to be_between(before + (2**attempt), after + (2**attempt)).inclusive
      end
    end

    it 'returns Result::Fail at attempt == DEFAULT_MAX_ATTEMPTS' do
      ex = RuntimeError.new('boom')
      result = Sidereal::Commander.on_error(ex, msg, meta_for(Sidereal::Commander::DEFAULT_MAX_ATTEMPTS))

      expect(result).to be_a(Sidereal::Store::Result::Fail)
      expect(result.error).to be(ex)
    end

    it 'is overridable on a subclass and receives (exception, message, meta)' do
      received = nil
      cmdr_class = Class.new(Sidereal::Commander) do
        define_singleton_method(:on_error) do |ex, msg, meta|
          received = [ex, msg, meta]
          Sidereal::Store::Result::Ack
        end
      end

      ex = RuntimeError.new('swallowed')
      meta = meta_for(2)
      result = cmdr_class.on_error(ex, msg, meta)

      expect(result).to eq(Sidereal::Store::Result::Ack)
      expect(received).to eq([ex, msg, meta])
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
    it 'publishes to the channel returned by self.class.channel_name' do
      cmdr_class = Class.new(Sidereal::Commander) do
        command TestAddItem do |cmd|
          broadcast TestNotification, text: 'hello'
        end

        def self.channel_name(_) = 'test-ch'
      end

      cmd = TestAddItem.new(payload: { title: 'x' })
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
