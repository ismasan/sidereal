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

TestSchedTick = Sidereal::Message.define('test.sched_tick') do
  attribute :n, Sidereal::Types::Integer
end

TestSchedExit = Sidereal::Message.define('test.sched_exit')

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

      expect(cmdr.handled_commands).to include(TestAddItem, TestSendEmail)
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

  describe '.schedule (Scheduling mixin)' do
    before { Sidereal.reset_scheduler! }
    after { Sidereal.reset_scheduler! }

    # Give each anonymous Commander a distinct toplevel name so the
    # auto-generated type strings don't collide across examples.
    # The constant is set BEFORE the body runs so +self.name+ is
    # already populated when +schedule+ derives type strings.
    def named_commander(const_name, &body)
      cls = Class.new(Sidereal::Commander)
      Object.const_set(const_name, cls)
      cls.class_eval(&body) if body
      cls
    end

    after do
      %i[CmdrA CmdrB CmdrC CmdrD CmdrE CmdrF].each do |c|
        Object.send(:remove_const, c) if Object.const_defined?(c, false)
      end
    end

    describe 'single-step shorthand (name, expression, &block)' do
      it 'registers a one-step schedule with the block as that step’s handler' do
        cmdr = named_commander(:CmdrA) do
          schedule 'Cleanup', '*/5 * * * *' do |_cmd|
          end
        end

        expect(cmdr::Schedules.const_defined?(:SchedCleanup0Step0, false)).to be true

        sch = Sidereal.scheduler.schedules.first
        expect(sch.name).to eq('Cleanup')
        expect(sch.steps.size).to eq(1)
        expect(sch.steps.first.expression).to eq('*/5 * * * *')
        expect(sch.steps.first.klass).to eq(cmdr::Schedules::SchedCleanup0Step0)
      end

      it 'yields the cmd to the user block (regular command handler)' do
        named_commander(:CmdrB) do
          command TestSchedTick do |_cmd| end
          schedule 'Cleanup', '*/5 * * * *' do |cmd|
            dispatch TestSchedTick, n: cmd.metadata[:schedule_name].length
          end
        end

        run_cmd = CmdrB::Schedules::SchedCleanup0Step0.new(
          metadata: { schedule_name: 'Cleanup' }
        )
        result = CmdrB.handle(run_cmd, pubsub: pubsub)

        expect(result.commands.first).to be_a(TestSchedTick)
        expect(result.commands.first.payload.n).to eq('Cleanup'.length)
      end

      it 'accepts a Time instance as the shorthand expression' do
        target = Time.local(2026, 5, 4, 12, 0, 0)
        named_commander(:CmdrC) do
          schedule 'Once', target do |_cmd| end
        end

        sch = Sidereal.scheduler.schedules.first
        expect(sch.steps.first.at).to eq(target)
      end

      it 'raises if the shorthand block has the wrong arity' do
        expect {
          named_commander(:CmdrD) do
            schedule 'Bad', '*/5 * * * *' do
              # arity 0 with an expression — invalid for shorthand
            end
          end
        }.to raise_error(ArgumentError, /requires a block of arity 1/)
      end
    end

    describe 'block form (auto-generated step classes)' do
      it 'generates one class per step under <Host>::Schedules and registers each with Sidereal.scheduler' do
        cmdr = named_commander(:CmdrA) do
          schedule 'Tick campaign' do
            at '2026-05-06T15:00:00' do |_cmd| end
            at 'every 3 seconds'    do |_cmd| end
            at '30s'                do |_cmd| end
          end
        end

        expect(cmdr::Schedules.const_defined?(:SchedTickCampaign0Step0, false)).to be true
        expect(cmdr::Schedules.const_defined?(:SchedTickCampaign0Step1, false)).to be true
        expect(cmdr::Schedules.const_defined?(:SchedTickCampaign0Step2, false)).to be true

        step0 = cmdr::Schedules::SchedTickCampaign0Step0
        expect(step0.type).to eq('cmdr_a.schedules.tick_campaign_0_step_0')

        sch = Sidereal.scheduler.schedules.first
        expect(sch.name).to eq('Tick campaign')
        expect(sch.steps.map(&:klass)).to eq([
          cmdr::Schedules::SchedTickCampaign0Step0,
          cmdr::Schedules::SchedTickCampaign0Step1,
          cmdr::Schedules::SchedTickCampaign0Step2
        ])
      end

      it 'wires the user block as the handler for the generated step class and propagates schedule_name via metadata' do
        named_commander(:CmdrB) do
          command TestSchedTick do |_cmd| end
          schedule 'Cleanup' do
            at '*/5 * * * *' do |cmd|
              dispatch TestSchedTick, n: cmd.metadata[:schedule_name].length
            end
          end
        end

        step_cmd = CmdrB::Schedules::SchedCleanup0Step0.new(
          metadata: { schedule_name: 'Cleanup', producer: "Schedule #0 'Cleanup' step #0 (*/5 * * * *)" }
        )
        result = CmdrB.handle(step_cmd, pubsub: pubsub)

        expect(result.commands.size).to eq(1)
        dispatched = result.commands.first
        expect(dispatched).to be_a(TestSchedTick)
        expect(dispatched.payload.n).to eq('Cleanup'.length)
        expect(dispatched.causation_id).to eq(step_cmd.id)
        expect(dispatched.metadata[:schedule_name]).to eq('Cleanup')
      end
    end

    describe 'explicit-class form (klass + payload, no block)' do
      it 'passes the user-supplied class through to the Scheduler without generating a class or handler' do
        cmdr = named_commander(:CmdrA) do
          schedule 'Flash sale campaign' do
            at '2026-05-10T10:00:00', TestSchedTick, n: 1
            at 'every day at 9am',    TestSchedTick, n: 2
            at '10d',                 TestSchedExit
          end
        end

        expect(cmdr::Schedules.constants).to be_empty

        sch = Sidereal.scheduler.schedules.first
        expect(sch.name).to eq('Flash sale campaign')
        expect(sch.steps.size).to eq(3)
        expect(sch.steps[0].klass).to eq(TestSchedTick)
        expect(sch.steps[0].payload).to eq(n: 1)
        expect(sch.steps[2].klass).to eq(TestSchedExit)
        expect(sch.steps[2].payload).to eq({})
      end

      it 'allows mixing block and explicit forms across steps' do
        cmdr = named_commander(:CmdrB) do
          command TestSchedExit do |_cmd| end
          schedule 'Mixed' do
            at '2026-05-10T10:00:00' do |_cmd| end                # generated
            at 'every minute', TestSchedTick, n: 1                # explicit
            at '1h', TestSchedExit                                # explicit
          end
        end

        expect(cmdr::Schedules.const_defined?(:SchedMixed0Step0, false)).to be true
        expect(cmdr::Schedules.const_defined?(:SchedMixed0Step1, false)).to be false
        expect(cmdr::Schedules.const_defined?(:SchedMixed0Step2, false)).to be false

        sch = Sidereal.scheduler.schedules.first
        expect(sch.steps[1].klass).to eq(TestSchedTick)
        expect(sch.steps[2].klass).to eq(TestSchedExit)
      end

      it 'raises when both a block and a class are supplied to the same at' do
        expect {
          named_commander(:CmdrC) do
            schedule 'Both' do
              at 'every minute', TestSchedTick, n: 1 do |_cmd| end
            end
          end
        }.to raise_error(ArgumentError, /pass either a block or a command class, not both/)
      end

      it 'a recurring step with neither a block nor a class raises (bound-only recurring is meaningless)' do
        expect {
          named_commander(:CmdrD) do
            schedule 'BadMarker' do
              at 'every minute'
            end
          end
        }.to raise_error(ArgumentError, /recurring step.*requires a command class/)
      end

      it 'a specific or duration step with no class is a bound-only marker (anchors the timeline, never dispatches)' do
        cmdr = named_commander(:CmdrA) do
          schedule 'Campaign' do
            at '2026-05-04T10:00:00'                       # marker — no class
            at '*/5 * * * *', TestSchedTick, n: 1          # recurring anchored to the marker
          end
        end

        # No class generated for the marker; only the recurring step
        # uses an explicit class so nothing under Schedules.
        expect(cmdr::Schedules.constants).to be_empty

        sch = Sidereal.scheduler.schedules.first
        expect(sch.steps[0].klass).to be_nil
        expect(sch.steps[0].at).to eq(Time.parse('2026-05-04T10:00:00'))
        expect(sch.steps[1].klass).to eq(TestSchedTick)
        expect(sch.steps[1].from).to eq(Time.parse('2026-05-04T10:00:00'))
      end
    end

    it 'raises if the schedule block has no at calls' do
      expect {
        named_commander(:CmdrA) do
          schedule 'Empty' do
            # no at(...) calls
          end
        end
      }.to raise_error(ArgumentError, /must declare at least one at/)
    end

    it 'raises if the schedule block takes arguments (must use the inner DSL)' do
      expect {
        named_commander(:CmdrE) do
          schedule 'Bad' do |_cmd|
          end
        end
      }.to raise_error(ArgumentError, /block must take no arguments/)
    end

    it 'each subclass of Commander gets its own Schedules namespace' do
      a = named_commander(:CmdrA) {}
      b = named_commander(:CmdrB) {}

      expect(a::Schedules).not_to equal(b::Schedules)
      expect(a::Schedules).not_to equal(Sidereal::Commander::Schedules)
    end

    it 'survives a schedule name that starts with a digit (Sched prefix keeps the constant valid)' do
      Object.const_set(:CmdrF, Class.new(Sidereal::Commander))
      CmdrF.class_eval do
        schedule '5 minute' do
          at '*/5 * * * *' do |_cmd| end
        end
      end

      expect(CmdrF::Schedules.const_defined?(:Sched5Minute0Step0, false)).to be true
    ensure
      Object.send(:remove_const, :CmdrF) if Object.const_defined?(:CmdrF, false)
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

    it 'returns Result::Retry for attempts below DEFAULT_MAX_ATTEMPTS' do
      ex = RuntimeError.new('boom')

      (1...Sidereal::Commander::DEFAULT_MAX_ATTEMPTS).each do |attempt|
        result = Sidereal::Commander.on_error(ex, msg, meta_for(attempt))
        expect(result).to be_a(Sidereal::Store::Result::Retry)
      end
    end

    it 'schedules retry with 2**attempt-second backoff' do
      ex = RuntimeError.new('boom')

      (1...Sidereal::Commander::DEFAULT_MAX_ATTEMPTS).each do |attempt|
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

      expect(cmdr_a.command_registry).to have_key('test.add_item')
      expect(cmdr_a.command_registry).not_to have_key('test.send_email')
      expect(cmdr_b.command_registry).to have_key('test.send_email')
      expect(cmdr_b.command_registry).not_to have_key('test.add_item')
    end
  end
end
