# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::Channels do
  subject(:channels) { described_class.new }

  let(:msg_a_class) { Sidereal::Message.define('test.cmd_a') }
  let(:msg_b_class) { Sidereal::Message.define('test.cmd_b') }
  let(:msg_c_class) { Sidereal::Message.define('test.cmd_c') }

  describe '#channel_name' do
    it 'registers a typed handler for one class' do
      channels.channel_name(msg_a_class) { |_| 'a-channel' }

      expect(channels.for(msg_a_class.new)).to eq('a-channel')
    end

    it 'registers the same block for multiple classes when given as positional args' do
      channels.channel_name(msg_a_class, msg_b_class) { |msg| "shared.#{msg.class.type}" }

      expect(channels.for(msg_a_class.new)).to eq('shared.test.cmd_a')
      expect(channels.for(msg_b_class.new)).to eq('shared.test.cmd_b')
    end

    it 'registers a catch-all when no message classes are given' do
      channels.channel_name { |_| 'catch-all' }

      expect(channels.for(msg_a_class.new)).to eq('catch-all')
    end

    it 'raises ArgumentError without a block' do
      expect { channels.channel_name(msg_a_class) }.to raise_error(ArgumentError, /block required/)
    end
  end

  describe '#for' do
    it 'is O(1) and does not walk class ancestors' do
      parent = Class.new(Sidereal::Message)
      child  = Class.new(parent)

      channels.channel_name(parent) { |_| 'parent-channel' }

      # A handler on the parent class does NOT match child instances.
      expect(channels.for(child.new)).to eq(Sidereal::Channels::DEFAULT_CHANNEL)
    end

    it 'falls back to the catch-all when the typed map misses' do
      channels.channel_name(msg_a_class) { |_| 'typed' }
      channels.channel_name { |_| 'fallback' }

      expect(channels.for(msg_a_class.new)).to eq('typed')
      expect(channels.for(msg_b_class.new)).to eq('fallback')
    end

    it 'falls back to the default "system" channel when nothing is registered' do
      expect(channels.for(msg_a_class.new)).to eq('system')
      expect(Sidereal::Channels::DEFAULT_CHANNEL).to eq('system')
    end

    it 'never raises on an unknown message — keeps publishing as the safe default' do
      expect { channels.for(msg_c_class.new) }.not_to raise_error
    end
  end

  describe '#reset!' do
    it 'clears typed and catch-all registrations' do
      channels.channel_name(msg_a_class) { |_| 'a' }
      channels.channel_name { |_| 'b' }
      channels.reset!

      expect(channels.for(msg_a_class.new)).to eq('system')
    end
  end

  describe 'Sidereal.channels (process-global)' do
    before { Sidereal.reset_channels! }

    it 'pre-registers the System::NotifyRetry source-channel bypass' do
      retry_msg = Sidereal::System::NotifyRetry.new(
        payload: { command_type: 'x', command_id: 'id', attempt: 1, retry_at: Time.now.iso8601, error_class: 'E', error_message: 'boom' },
        metadata: { source_channel: 'campaigns.42' }
      )

      expect(Sidereal.channels.for(retry_msg)).to eq('campaigns.42')
    end

    it 'pre-registers the System::NotifyFailure source-channel bypass' do
      fail_msg = Sidereal::System::NotifyFailure.new(
        payload: { command_type: 'x', command_id: 'id', attempt: 1, error_class: 'E', error_message: 'boom' },
        metadata: { source_channel: 'campaigns.42' }
      )

      expect(Sidereal.channels.for(fail_msg)).to eq('campaigns.42')
    end

    it "falls back to 'system' when source_channel is not stamped" do
      retry_msg = Sidereal::System::NotifyRetry.new(
        payload: { command_type: 'x', command_id: 'id', attempt: 1, retry_at: Time.now.iso8601, error_class: 'E', error_message: 'boom' }
      )

      expect(Sidereal.channels.for(retry_msg)).to eq('system')
    end
  end
end
