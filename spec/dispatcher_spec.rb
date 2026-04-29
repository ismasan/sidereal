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

      def self.channel_name(_) = 'ch1'
    end
  end

  it 'publishes the command and its events to pubsub' do
    cmd = DispatchCmd.new(payload: { title: 'hello' })
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

      def self.channel_name(_) = 'ch1'
    end

    cmd = DispatchCmd.new(payload: { title: 'original' })
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

      def self.channel_name(_) = 'ch1'
    end

    store.append(DispatchCmd.new(payload: { title: 'a' }))
    store.append(DispatchOtherCmd.new(payload: { note: 'b' }))

    run_and_collect('ch1', store: store, registry: registry_for(multi_commander), pubsub: pubsub) {}

    expect(seen).to contain_exactly([:do_thing, 'a'], [:other, 'b'])
  end

  it 'silently skips messages with no registered handler' do
    seen = []

    cmdr = Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        seen << cmd.payload.title
      end

      def self.channel_name(_) = 'ch1'
    end

    # First, an unhandled command — should be a noop
    store.append(DispatchOtherCmd.new(payload: { note: 'ignored' }))
    # Then, a handled command — worker should still be alive
    store.append(DispatchCmd.new(payload: { title: 'kept' }))

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

      def self.channel_name(_) = 'ch1'
    end

    store.append(DispatchCmd.new(payload: { title: 'first' }))
    store.append(DispatchCmd.new(payload: { title: 'second' }))
    store.append(DispatchCmd.new(payload: { title: 'third' }))

    run_and_collect('ch1', store: store, registry: registry_for(ordered_commander), pubsub: pubsub) {}

    expect(titles).to eq(%w[first second third])
  end

  it 'routes via the commander, computing the channel from each message' do
    routed = { 'a' => [], 'b' => [] }

    routing_commander = Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        dispatch DispatchEvt, title: cmd.payload.title
      end

      define_singleton_method(:channel_name) do |msg|
        # Use payload to choose channel — exercises that channel_name
        # receives the message and can switch on it.
        msg.is_a?(DispatchEvt) ? "evt-#{msg.payload.title}" : 'cmds'
      end
    end

    store.append(DispatchCmd.new(payload: { title: 'a' }))

    received_cmds = nil
    received_evt = nil
    Sync do |task|
      cmds = pubsub.subscribe('cmds')
      evt = pubsub.subscribe('evt-a')

      received_cmds = []
      received_evt = []
      task.async { cmds.start { |m, _| received_cmds << m } }
      task.async { evt.start { |m, _| received_evt << m } }

      Sidereal::Dispatcher.new(
        worker_count: 1, store: store, registry: registry_for(routing_commander), pubsub: pubsub
      ).spawn_into(task)

      task.async do
        sleep 0.05
        cmds.stop
        evt.stop
        task.stop
      end.wait
    end

    expect(received_cmds.map(&:class)).to eq([DispatchCmd])
    expect(received_evt.map(&:class)).to eq([DispatchEvt])
  end

  it 'skips publish when the handler raises (and worker survives if on_error swallows)' do
    handled = []
    raising_commander = Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        raise 'boom' if cmd.payload.title == 'bad'
        dispatch DispatchEvt, cmd.payload.to_h
      end
      define_singleton_method(:on_error) { |ex| handled << ex }

      def self.channel_name(_) = 'ch1'
    end

    store.append(DispatchCmd.new(payload: { title: 'bad' }))
    store.append(DispatchCmd.new(payload: { title: 'good' }))

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

      def self.channel_name(_) = 'ch1'
    end

    store.append(DispatchCmd.new(payload: { title: 'first' }))
    store.append(DispatchCmd.new(payload: { title: 'second' }))

    received = run_and_collect('ch1', store: store, registry: registry_for(cmdr), pubsub: flaky_pubsub) {}

    # Both handlers ran (handler success → no retry on publish failure)
    expect(handled_titles).to eq(%w[first second])
    # First publish raised and was swallowed; second succeeded
    expect(received.map { |m| m.payload.title }).to eq(['second'])
  end
end
