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

  # Inject a per-spec exceptions registry. Default = clean (no
  # subscribers, no default publisher), so the success-path tests
  # don't get extra noise. The +system notifications+ block below
  # overrides with capturing subscribers.
  let(:exceptions) { Sidereal::Exceptions.new }

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
  def run_and_collect(channel_name, store:, registry:, pubsub:, channels: self.channels, exceptions: self.exceptions, &block)
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
        channels: channels,
        exceptions: exceptions
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
        worker_count: 1, store: store, registry: registry_for(routing_commander),
        pubsub: pubsub, channels: channels, exceptions: exceptions
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
    expect(meta.retry_count).to eq(1)

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

    failure_reports = []
    capturing_exceptions = Sidereal::Exceptions.new.tap do |e|
      e.on_failure { |r| failure_reports << r }
    end

    store.append(DispatchCmd.new(payload: { title: 'bad' }))
    store.append(DispatchCmd.new(payload: { title: 'good' }))

    received = run_and_collect('ch1',
      store: store, registry: registry_for(raising_commander),
      pubsub: pubsub, exceptions: capturing_exceptions
    ) {}

    # The 'bad' message was logged + dropped (Memory store can't dead-letter).
    # The worker survives and processes the next message.
    expect(received.map(&:class)).to eq([DispatchCmd, DispatchEvt])
    expect(received[0].payload.title).to eq('good')

    # When on_error raises, the dispatcher falls back to Result::Fail
    # with the original exception — confirm a failure report fired.
    expect(failure_reports.size).to eq(1)
    expect(failure_reports.first.exception.message).to eq('boom')
    expect(failure_reports.first.message.payload.title).to eq('bad')
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
    # Override the outer +exceptions+ let with one that captures
    # reports for assertion. No default publisher — we're testing
    # the dispatcher's contract with the registry, not the publisher.
    let(:retry_reports)   { [] }
    let(:failure_reports) { [] }
    let(:exceptions) do
      Sidereal::Exceptions.new.tap do |e|
        e.on_retry   { |report| retry_reports   << report }
        e.on_failure { |report| failure_reports << report }
      end
    end

    def build_commander(failing_cmd_class:, on_error_result:)
      Class.new(Sidereal::Commander) do
        command(failing_cmd_class) { |_cmd| raise 'boom' }
        define_singleton_method(:on_error) { |_ex, _msg, _meta| on_error_result }
      end
    end

    it 'reports a retry to Sidereal.exceptions when policy is Retry' do
      retry_at = Time.now + 60
      cmdr = build_commander(
        failing_cmd_class: DispatchCmd,
        on_error_result: Sidereal::Store::Result::Retry.new(at: retry_at)
      )

      cmd = DispatchCmd.new(payload: { title: 'doomed' })
      store.append(cmd)

      run_and_collect('ch1', store: store, registry: registry_for(cmdr), pubsub: pubsub) {}

      expect(retry_reports.size).to eq(1)
      r = retry_reports.first
      expect(r).to be_a(Sidereal::ExceptionReport)
      expect(r).to be_retry
      expect(r.message).to eq(cmd)
      expect(r.exception).to be_a(RuntimeError)
      expect(r.exception.message).to eq('boom')
      expect(r.retry_count).to eq(1)
      expect(r.retry_at).to be_within(0.001).of(retry_at)
      expect(failure_reports).to be_empty
    end

    it 'reports a failure to Sidereal.exceptions when policy is Fail' do
      cmdr = build_commander(
        failing_cmd_class: DispatchCmd,
        on_error_result: Sidereal::Store::Result::Fail.new(error: RuntimeError.new('boom'))
      )

      cmd = DispatchCmd.new(payload: { title: 'doomed' })
      store.append(cmd)

      run_and_collect('ch1', store: store, registry: registry_for(cmdr), pubsub: pubsub) {}

      expect(failure_reports.size).to eq(1)
      f = failure_reports.first
      expect(f).to be_failure
      expect(f.message).to eq(cmd)
      expect(f.exception).to be_a(RuntimeError)
      expect(f.exception.message).to eq('boom')
      expect(f.retry_count).to eq(1)
      expect(f.retry_at).to be_nil
      expect(retry_reports).to be_empty
    end

    it 'does NOT report when policy is Ack' do
      cmdr = build_commander(
        failing_cmd_class: DispatchCmd,
        on_error_result: Sidereal::Store::Result::Ack
      )

      store.append(DispatchCmd.new(payload: { title: 'swallowed' }))

      run_and_collect('ch1', store: store, registry: registry_for(cmdr), pubsub: pubsub) {}

      expect(retry_reports).to be_empty
      expect(failure_reports).to be_empty
    end

    it 'breaks the loop: a failing System::Notification does not trigger another report' do
      # The dispatcher's report-call site short-circuits when the
      # failing message is itself a System::Notification, so a
      # buggy on_failure subscriber's eventual death (or any other
      # path that lands a system message back in the store) does
      # not cascade into another report-and-fan-out.
      cmdr = Class.new(Sidereal::Commander) do
        command(Sidereal::System::NotifyFailure) { |_cmd| raise 'NotifyFailure handler broken' }
        define_singleton_method(:on_error) do |_ex, _msg, _meta|
          Sidereal::Store::Result::Fail.new(error: RuntimeError.new('boom'))
        end
      end

      store.append(Sidereal::System::NotifyFailure.new(
        payload: {
          command_type: 'foo',
          command_id: SecureRandom.uuid,
          retry_count: 1,
          error_class: 'RuntimeError',
          error_message: 'upstream',
          backtrace: []
        }
      ))

      run_and_collect('ch1', store: store, registry: registry_for(cmdr), pubsub: pubsub) {}

      expect(retry_reports).to be_empty
      expect(failure_reports).to be_empty
    end
  end
end
