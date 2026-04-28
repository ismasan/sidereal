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

DispatchOtherCmd = Sidereal::Message.define('dispatch_spec.other_thing') do
  attribute :note, Sidereal::Types::String
end

RSpec.describe Sidereal::Dispatcher do
  let(:store) { Sidereal::Store::Memory.new }
  let(:pubsub) { Sidereal::PubSub::Memory.new }

  def registry_for(*commanders)
    Sidereal::Registry.new.tap do |r|
      commanders.each do |c|
        c.handled_commands.each { |cmd_class| r[cmd_class] = c }
      end
    end
  end

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

    received = run_and_collect('ch1', store: store, registry: registry_for(commander), pubsub: pubsub) {}

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

    received = run_and_collect('ch1', store: store, registry: registry_for(commander_with_followup), pubsub: pubsub) {}

    followups = received.select { |m| m.is_a?(DispatchFollowUp) }
    expect(followups.size).to eq(1)
  end

  it 'routes each command to its single registered handler' do
    seen = []

    multi_commander = Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        seen << [:do_thing, cmd.payload.title]
      end
      command DispatchOtherCmd do |cmd|
        seen << [:other, cmd.payload.note]
      end
    end

    store.append(DispatchCmd.new(payload: { title: 'a' }, metadata: { channel: 'ch1' }))
    store.append(DispatchOtherCmd.new(payload: { note: 'b' }, metadata: { channel: 'ch1' }))

    run_and_collect('ch1', store: store, registry: registry_for(multi_commander), pubsub: pubsub) {}

    expect(seen).to contain_exactly([:do_thing, 'a'], [:other, 'b'])
  end

  it 'silently skips messages with no registered handler' do
    seen = []

    cmdr = Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        seen << cmd.payload.title
      end
    end

    # First, an unhandled command — should be a noop
    store.append(DispatchOtherCmd.new(payload: { note: 'ignored' }, metadata: { channel: 'ch1' }))
    # Then, a handled command — worker should still be alive
    store.append(DispatchCmd.new(payload: { title: 'kept' }, metadata: { channel: 'ch1' }))

    received = run_and_collect('ch1', store: store, registry: registry_for(cmdr), pubsub: pubsub) {}

    expect(seen).to eq(['kept'])
    expect(received.map(&:class)).to eq([DispatchCmd])
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

    run_and_collect('ch1', store: store, registry: registry_for(ordered_commander), pubsub: pubsub) {}

    expect(titles).to eq(%w[first second third])
  end

  it 'skips publish when the handler raises (and worker survives if on_error swallows)' do
    handled = []
    raising_commander = Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        raise 'boom' if cmd.payload.title == 'bad'
        dispatch DispatchEvt, cmd.payload.to_h
      end
      define_singleton_method(:on_error) { |ex| handled << ex }
    end

    store.append(DispatchCmd.new(payload: { title: 'bad' }, metadata: { channel: 'ch1' }))
    store.append(DispatchCmd.new(payload: { title: 'good' }, metadata: { channel: 'ch1' }))

    received = run_and_collect('ch1', store: store, registry: registry_for(raising_commander), pubsub: pubsub) {}

    expect(handled.map(&:message)).to eq(['boom'])
    # Only the 'good' command's msg + event were published; the failed one was not broadcast.
    expect(received.map(&:class)).to eq([DispatchCmd, DispatchEvt])
    expect(received[0].payload.title).to eq('good')
  end

  it 'swallows publish errors and continues processing' do
    flaky_pubsub = Object.new
    real_pubsub = pubsub
    call_count = 0
    flaky_pubsub.define_singleton_method(:publish) do |channel, msg|
      call_count += 1
      raise 'pubsub down' if call_count == 1
      real_pubsub.publish(channel, msg)
    end
    flaky_pubsub.define_singleton_method(:subscribe) { |c| real_pubsub.subscribe(c) }

    handled_titles = []
    cmdr = Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        handled_titles << cmd.payload.title
      end
    end

    store.append(DispatchCmd.new(payload: { title: 'first' }, metadata: { channel: 'ch1' }))
    store.append(DispatchCmd.new(payload: { title: 'second' }, metadata: { channel: 'ch1' }))

    received = run_and_collect('ch1', store: store, registry: registry_for(cmdr), pubsub: flaky_pubsub) {}

    # Both handlers ran (handler success → no retry on publish failure)
    expect(handled_titles).to eq(%w[first second])
    # First publish raised and was swallowed; second succeeded
    expect(received.map { |m| m.payload.title }).to eq(['second'])
  end
end
