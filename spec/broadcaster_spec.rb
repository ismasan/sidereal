# frozen_string_literal: true

require 'spec_helper'

BroadcasterSpecCmd = Sidereal::Message.define('broadcaster_spec.cmd') do
  attribute :title, Sidereal::Types::String
end

BroadcasterSpecNote = Sidereal::Message.define('broadcaster_spec.note') do
  attribute :text, Sidereal::Types::String
end

RSpec.describe Sidereal::Broadcaster do
  let(:pubsub) do
    Class.new do
      attr_reader :published

      def initialize = @published = []
      def start(_task) = self
      def subscribe(_pattern) = nil
      def publish(channel, message) = @published << [channel, message]
    end.new
  end

  subject(:broadcaster) { described_class.new(pubsub:, channels: Sidereal.channels) }

  describe '#broadcast' do
    it 'publishes the message on the channel resolved for it' do
      Sidereal.channels.channel_name(BroadcasterSpecNote) { |m| "notes.#{m.payload.text}" }
      note = BroadcasterSpecNote.new(payload: { text: 'hi' })

      broadcaster.broadcast(note)

      expect(pubsub.published).to eq([['notes.hi', note]])
    end

    it 'correlates the message to from:, and returns what it published' do
      cmd = BroadcasterSpecCmd.new(payload: { title: 'x' })

      published = broadcaster.broadcast(BroadcasterSpecNote.new(payload: { text: 'hi' }), from: cmd)

      expect(published.causation_id).to eq(cmd.id)
      expect(published.correlation_id).to eq(cmd.correlation_id)
      expect(pubsub.published).to eq([[Sidereal.channels.for(published), published]])
    end

    it 'leaves the message uncorrelated without from:' do
      note = BroadcasterSpecNote.new(payload: { text: 'hi' })

      expect(broadcaster.broadcast(note)).to be(note)
    end
  end

  describe 'the sidereal.broadcaster component' do
    it 'builds a Broadcaster' do
      Sidereal.config.build!

      expect(Sidereal.broadcaster).to be_a(described_class)
    end

    it 'publishes to the sidereal.pubsub component' do
      fake = pubsub
      Sidereal.config.config!('sidereal.pubsub') { fake }
      Sidereal.config.build!
      note = BroadcasterSpecNote.new(payload: { text: 'hi' })

      Sidereal.broadcaster.broadcast(note)

      expect(fake.published.map(&:last)).to eq([note])
    end

    it "is the one a commander's broadcast goes through by default" do
      captured = []
      Sidereal.config.component!('sidereal.broadcaster') do
        build do
          Class.new do
            define_method(:broadcast) { |msg, from:| captured << [msg, from] }
          end.new
        end
      end
      Sidereal.config.build!
      commander = Class.new(Sidereal::Commander) do
        command(BroadcasterSpecCmd) { |_cmd| broadcast BroadcasterSpecNote, text: 'working' }
      end
      cmd = BroadcasterSpecCmd.new(payload: { title: 'x' })

      commander.handle(cmd)

      expect(captured.map { |msg, _| msg.payload.text }).to eq(['working'])
      expect(captured.map(&:last)).to eq([cmd])
    end
  end
end
