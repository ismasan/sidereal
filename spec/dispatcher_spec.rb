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

  # Inject a per-spec channel registry rather than mutating
  # +Sidereal.channels+. Pre-loaded with the System notification
  # bypass + a catch-all that routes every domain message to 'ch1'
  # (the channel most tests subscribe to).
  let(:channels) do
    Sidereal::Channels.with_system_defaults.tap do |c|
      c.channel_name { |_| 'ch1' }
    end
  end

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
  def run_and_collect(channel_name, store:, registry:, pubsub:, channels: self.channels, &block)
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
        pubsub: pubsub,
        channels: channels
      ).start(task)

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

  it 'resolves the channel via the injected Channels for each published message' do
    routing_commander = Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        dispatch DispatchEvt, title: cmd.payload.title
      end
    end

    # Per-class registrations override the catch-all baked into the
    # +channels+ let.
    channels.channel_name(DispatchCmd) { |_| 'cmds' }
    channels.channel_name(DispatchEvt) { |msg| "evt-#{msg.payload.title}" }

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
        worker_count: 1, store: store, registry: registry_for(routing_commander), pubsub: pubsub, channels: channels
      ).start(task)

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
    on_error_calls = []
    raising_commander = Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        raise 'boom' if cmd.payload.title == 'bad'
        dispatch DispatchEvt, cmd.payload.to_h
      end
      define_singleton_method(:on_error) do |ex, msg, meta|
        on_error_calls << [ex, msg, meta]
        Sidereal::Store::Result::Ack
      end

      def self.channel_name(_) = 'ch1'
    end

    store.append(DispatchCmd.new(payload: { title: 'bad' }))
    store.append(DispatchCmd.new(payload: { title: 'good' }))

    received = run_and_collect('ch1', store: store, registry: registry_for(raising_commander), pubsub: pubsub) {}

    expect(on_error_calls.size).to eq(1)
    ex, msg, meta = on_error_calls[0]
    expect(ex.message).to eq('boom')
    expect(msg).to be_a(DispatchCmd)
    expect(msg.payload.title).to eq('bad')
    expect(meta).to be_a(Sidereal::Store::Meta)
    expect(meta.attempt).to eq(1)

    # Only the 'good' command's msg + event were published; the failed one was not broadcast.
    expect(received.map(&:class)).to eq([DispatchCmd, DispatchEvt])
    expect(received[0].payload.title).to eq('good')
  end

  it 'survives when on_error itself raises' do
    raising_commander = Class.new(Sidereal::Commander) do
      command DispatchCmd do |cmd|
        raise 'boom' if cmd.payload.title == 'bad'
        dispatch DispatchEvt, cmd.payload.to_h
      end
      define_singleton_method(:on_error) { |_ex, _msg, _meta| raise 'on_error itself blew up' }

      def self.channel_name(_) = 'ch1'
    end

    store.append(DispatchCmd.new(payload: { title: 'bad' }))
    store.append(DispatchCmd.new(payload: { title: 'good' }))

    received = run_and_collect('ch1', store: store, registry: registry_for(raising_commander), pubsub: pubsub) {}

    # The 'bad' message was logged + dropped (Memory store can't dead-letter).
    # The worker survives and processes the next message. A NotifyFailure
    # is also emitted for 'bad' (auto-handled at no-op via Commander's
    # inherited hook); filter it out for the user-command assertions.
    user_received = received.reject { |m| m.is_a?(Sidereal::System::NotifyFailure) }
    expect(user_received.map(&:class)).to eq([DispatchCmd, DispatchEvt])
    expect(user_received[0].payload.title).to eq('good')
    # And confirm the NotifyFailure for the 'bad' command did flow through.
    expect(received.map(&:class)).to include(Sidereal::System::NotifyFailure)
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

  describe 'system notifications' do
    # Build a commander that raises on a configurable cmd class, plus
    # no-op handlers for the system notifications so they flow through
    # the normal pipeline (handle → publish).
    def build_commander(failing_cmd_class:, on_error_result:, channel: 'ch1', notify_calls: nil)
      Class.new(Sidereal::Commander) do
        command(failing_cmd_class) { |_cmd| raise 'boom' }
        command(Sidereal::System::NotifyRetry) do |cmd|
          notify_calls << cmd if notify_calls
        end
        command(Sidereal::System::NotifyFailure) do |cmd|
          notify_calls << cmd if notify_calls
        end

        define_singleton_method(:on_error) { |_ex, _msg, _meta| on_error_result }
        define_singleton_method(:channel_name) { |_msg| channel }
      end
    end

    it 'dispatches NotifyRetry with full payload after handler raises' do
      retry_at = Time.now + 60
      notify_calls = []
      cmdr = build_commander(
        failing_cmd_class: DispatchCmd,
        on_error_result: Sidereal::Store::Result::Retry.new(at: retry_at),
        notify_calls: notify_calls
      )

      cmd = DispatchCmd.new(payload: { title: 'doomed' })
      store.append(cmd)

      run_and_collect('ch1', store: store, registry: registry_for(cmdr), pubsub: pubsub) {}

      retries = notify_calls.select { |c| c.is_a?(Sidereal::System::NotifyRetry) }
      expect(retries.size).to eq(1)
      r = retries.first
      expect(r.payload.command_type).to eq(DispatchCmd.type)
      expect(r.payload.command_id).to eq(cmd.id)
      expect(r.payload.command_payload).to eq(title: 'doomed')
      expect(r.payload.attempt).to eq(1)
      expect(r.payload.error_class).to eq('RuntimeError')
      expect(r.payload.error_message).to eq('boom')
      expect(r.payload.backtrace).not_to be_empty
      expect(Time.parse(r.payload.retry_at)).to be_within(0.001).of(retry_at)
      # Correlated to the source command
      expect(r.causation_id).to eq(cmd.id)
      expect(r.correlation_id).to eq(cmd.correlation_id)
    end

    it 'dispatches NotifyFailure with full payload when policy is Fail' do
      notify_calls = []
      cmdr = build_commander(
        failing_cmd_class: DispatchCmd,
        on_error_result: Sidereal::Store::Result::Fail.new(error: RuntimeError.new('boom')),
        notify_calls: notify_calls
      )

      cmd = DispatchCmd.new(payload: { title: 'doomed' })
      store.append(cmd)

      run_and_collect('ch1', store: store, registry: registry_for(cmdr), pubsub: pubsub) {}

      failures = notify_calls.select { |c| c.is_a?(Sidereal::System::NotifyFailure) }
      expect(failures.size).to eq(1)
      f = failures.first
      expect(f.payload.command_type).to eq(DispatchCmd.type)
      expect(f.payload.command_id).to eq(cmd.id)
      expect(f.payload.error_message).to eq('boom')
    end

    it 'does NOT dispatch a notification when policy is Ack' do
      notify_calls = []
      cmdr = build_commander(
        failing_cmd_class: DispatchCmd,
        on_error_result: Sidereal::Store::Result::Ack,
        notify_calls: notify_calls
      )

      store.append(DispatchCmd.new(payload: { title: 'swallowed' }))

      run_and_collect('ch1', store: store, registry: registry_for(cmdr), pubsub: pubsub) {}

      expect(notify_calls).to be_empty
    end

    it 'does NOT dispatch when no handler is registered for the notification' do
      # Commander auto-handles system notifications via Commander.inherited,
      # but build a registry that deliberately omits them — simulates the
      # case where the wiring didn't include system handlers.
      cmdr = Class.new(Sidereal::Commander) do
        command(DispatchCmd) { |_cmd| raise 'boom' }
        define_singleton_method(:on_error) do |_ex, _msg, _meta|
          Sidereal::Store::Result::Fail.new(error: RuntimeError.new('boom'))
        end
        def self.channel_name(_) = 'ch1'
      end

      registry = Sidereal::Registry.new
      registry[DispatchCmd] = cmdr
      # Deliberately do NOT register NotifyRetry/NotifyFailure.

      store.append(DispatchCmd.new(payload: { title: 'orphan' }))

      received = run_and_collect('ch1', store: store, registry: registry, pubsub: pubsub, channels: channels) {}

      # No NotifyFailure should appear in the channel — dispatcher
      # detected no handler and skipped the dispatch.
      expect(received.map(&:class)).not_to include(Sidereal::System::NotifyFailure)
    end

    it 'a domain-specific channel_name resolver does not crash on system notifications' do
      # Mirrors the donations1 demo: channel_name block reads a payload
      # key that exists on the user command but NOT on system messages.
      # Without the App.channel_name wrapper this would raise KeyError
      # the moment a NotifyFailure flows through publish.
      cmdr = Class.new(Sidereal::Commander) do
        command(DispatchCmd) { |_cmd| raise 'boom' }
        command(Sidereal::System::NotifyRetry)
        command(Sidereal::System::NotifyFailure)

        define_singleton_method(:on_error) do |_ex, _msg, _meta|
          Sidereal::Store::Result::Fail.new(error: RuntimeError.new('boom'))
        end
      end

      # Register a domain-specific resolver on the injected registry —
      # this is what was previously installed via App.channel_name.
      # System notifications continue to route via the pre-installed
      # source_channel bypass (Channels.with_system_defaults), so the
      # resolver below never sees them.
      channels.channel_name(DispatchCmd) do |msg|
        "ch.#{msg.payload.fetch(:title)}"
      end

      store.append(DispatchCmd.new(payload: { title: 'doomed' }))

      received = run_and_collect('ch.doomed', store: store, registry: registry_for(cmdr), pubsub: pubsub) {}

      # NotifyFailure landed on the same channel the user resolver
      # would have computed for the source command, via the stamped
      # source_channel metadata — and crucially, no KeyError crashed
      # the worker on its way through publish.
      expect(received.map(&:class)).to include(Sidereal::System::NotifyFailure)
    end

    it 'breaks the loop: NotifyFailure handler raising does not produce another NotifyFailure' do
      notify_calls = []
      cmdr = Class.new(Sidereal::Commander) do
        # NotifyFailure handler always raises — would loop without the guard
        command(Sidereal::System::NotifyFailure) do |cmd|
          notify_calls << cmd
          raise 'NotifyFailure handler also broken'
        end
        command(Sidereal::System::NotifyRetry)

        define_singleton_method(:on_error) do |_ex, _msg, _meta|
          Sidereal::Store::Result::Fail.new(error: RuntimeError.new('boom'))
        end
        def self.channel_name(_) = 'ch1'
      end

      # Append a NotifyFailure directly — simulates the case where one
      # was dispatched for an upstream command and now also fails.
      store.append(Sidereal::System::NotifyFailure.new(
        payload: {
          command_type: 'foo',
          command_id: SecureRandom.uuid,
          attempt: 1,
          error_class: 'RuntimeError',
          error_message: 'upstream',
          backtrace: []
        }
      ))

      run_and_collect('ch1', store: store, registry: registry_for(cmdr), pubsub: pubsub) {}

      # The handler ran exactly once (and raised). Without loop prevention
      # it would re-trigger another NotifyFailure for itself.
      expect(notify_calls.size).to eq(1)
    end
  end
end
