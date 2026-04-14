# frozen_string_literal: true

require 'spec_helper'
require 'sidereal/dispatcher'
require 'async'

DispatchCmd = Sidereal::Message.define('dispatch_spec.do_thing') do
  attribute :title, Sidereal::Types::String
end

DispatchEvt = Sidereal::Message.define('dispatch_spec.thing_done') do
  attribute :title, Sidereal::Types::String
end

DispatchFollowUp = Sidereal::Message.define('dispatch_spec.follow_up') do
  attribute :ref, Sidereal::Types::String
end

RSpec.describe Sidereal::Dispatcher do
  let(:store) { Sidereal::Store::Memory.new }
  let(:pubsub) { Sidereal::PubSub::Memory.new }

  # Run the dispatcher, subscribe to a channel, and collect published messages.
  # Yields a block where the caller can append commands to the store.
  # Returns the list of messages received on the channel.
  def run_and_collect(channel_name, store:, registry:, pubsub:, &block)
    received = []

    Sync do |task|
      channel = pubsub.subscribe(channel_name)

      # Collect messages from pubsub
      consumer = task.async do
        channel.start do |msg, ch|
          received << msg
        end
      end

      Sidereal::Dispatcher.new(
        worker_count: 1,
        store: store,
        registry: registry,
        pubsub: pubsub
      ).spawn_into(task)

      task.async do
        block.call if block
        sleep 0.05
        channel.stop
        task.stop
      end.wait
    end

    received
  end

  let(:commander) do
    Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        dispatch DispatchEvt, cmd.payload.to_h
      end
      command DispatchFollowUp
    end
  end

  it 'publishes the command and its events to pubsub' do
    cmd = DispatchCmd.new(payload: { title: 'hello' }, metadata: { channel: 'ch1' })
    store.append(cmd)

    received = run_and_collect('ch1', store: store, registry: [commander], pubsub: pubsub) {}

    expect(received.size).to eq(2)
    expect(received[0]).to be_a(DispatchCmd)
    expect(received[1]).to be_a(DispatchEvt)
    expect(received[1].payload.title).to eq('hello')
  end

  it 're-appends follow-up commands to the store and processes them' do
    commander_with_followup = Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        dispatch DispatchFollowUp, ref: cmd.payload.title
      end
      command DispatchFollowUp
    end

    cmd = DispatchCmd.new(payload: { title: 'original' }, metadata: { channel: 'ch1' })
    store.append(cmd)

    received = run_and_collect('ch1', store: store, registry: [commander_with_followup], pubsub: pubsub) {}

    followups = received.select { |m| m.is_a?(DispatchFollowUp) }
    expect(followups.size).to eq(1)
  end

  it 'fans out each command to all registered commanders' do
    called = []

    commander_a = Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        called << :a
      end
    end

    commander_b = Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        called << :b
      end
    end

    cmd = DispatchCmd.new(payload: { title: 'hello' }, metadata: { channel: 'ch1' })
    store.append(cmd)

    run_and_collect('ch1', store: store, registry: [commander_a, commander_b], pubsub: pubsub) {}

    expect(called).to contain_exactly(:a, :b)
  end

  it 'processes multiple commands in order' do
    titles = []

    ordered_commander = Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        titles << cmd.payload.title
      end
    end

    store.append(DispatchCmd.new(payload: { title: 'first' }, metadata: { channel: 'ch1' }))
    store.append(DispatchCmd.new(payload: { title: 'second' }, metadata: { channel: 'ch1' }))
    store.append(DispatchCmd.new(payload: { title: 'third' }, metadata: { channel: 'ch1' }))

    run_and_collect('ch1', store: store, registry: [ordered_commander], pubsub: pubsub) {}

    expect(titles).to eq(%w[first second third])
  end
end
