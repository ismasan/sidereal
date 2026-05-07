# frozen_string_literal: true

require 'spec_helper'

# Test message classes — lightweight stand-ins for whatever a host
# would dispatch through its scheduler.
TestSchedulingTick = Sidereal::Message.define('test.scheduling_tick') do
  attribute :n, Sidereal::Types::Integer
end

TestSchedulingExit = Sidereal::Message.define('test.scheduling_exit')

RSpec.describe Sidereal::Scheduling do
  before { Sidereal.reset_scheduler! }
  after  { Sidereal.reset_scheduler! }

  # A minimal stand-in that satisfies the Scheduling mixin's host
  # contract: it just needs to expose +.command(klass, &block)+. The
  # generated handlers are recorded so tests can inspect them; no
  # actual command-handling pipeline runs here. This isolates the
  # mixin's behaviour from any Commander-specific machinery.
  def make_test_host(const_name, &body)
    cls = Class.new do
      def self.commands_registered
        @commands_registered ||= {}
      end

      def self.command(klass, &block)
        commands_registered[klass] = block
        self
      end

      include Sidereal::Scheduling
    end
    Object.const_set(const_name, cls)
    cls.class_eval(&body) if body
    cls
  end

  after do
    %i[HostA HostB HostC HostD HostE HostF].each do |c|
      Object.send(:remove_const, c) if Object.const_defined?(c, false)
    end
  end

  describe 'host contract' do
    it 'creates a Schedules namespace on the host when included' do
      host = make_test_host(:HostA)
      expect(host::Schedules).to be_a(Module)
    end

    it 'gives each subclass its own Schedules namespace' do
      host = make_test_host(:HostA)
      sub  = Class.new(host)

      expect(sub::Schedules).not_to equal(host::Schedules)
    end

    it 'is host-agnostic — works on any class that exposes #command' do
      # No Commander, no App, no Sidereal::Message inheritance — just a
      # class with a +command+ class method.
      host = make_test_host(:HostA) do
        schedule 'Hourly', '0 * * * *' do |_cmd| end
      end

      expect(host::Schedules.const_defined?(:SchedHourly0Step0, false)).to be true
      expect(Sidereal.scheduler.schedules.first.name).to eq('Hourly')
    end
  end

  describe 'single-step shorthand (name, expression, &block)' do
    it 'registers a one-step schedule with the block as that step’s handler' do
      host = make_test_host(:HostA) do
        schedule 'Cleanup', '*/5 * * * *' do |_cmd| end
      end

      expect(host::Schedules.const_defined?(:SchedCleanup0Step0, false)).to be true

      sch = Sidereal.scheduler.schedules.first
      expect(sch.name).to eq('Cleanup')
      expect(sch.steps.size).to eq(1)
      expect(sch.steps.first.expression).to eq('*/5 * * * *')
      expect(sch.steps.first.klass).to eq(host::Schedules::SchedCleanup0Step0)
    end

    it 'records the user block on the host as the handler for the generated step class' do
      handler_block = nil
      host = make_test_host(:HostB) do
        schedule 'Cleanup', '*/5 * * * *' do |cmd|
          # body of the handler — captured by the host's #command
          cmd.metadata[:schedule_name]
        end
      end

      step_class = host::Schedules::SchedCleanup0Step0
      handler_block = host.commands_registered[step_class]

      expect(handler_block).to be_a(Proc)
      expect(handler_block.arity).to eq(1)
    end

    it 'accepts a Time instance as the shorthand expression' do
      target = Time.local(2026, 5, 4, 12, 0, 0)
      make_test_host(:HostC) do
        schedule 'Once', target do |_cmd| end
      end

      sch = Sidereal.scheduler.schedules.first
      expect(sch.steps.first.at).to eq(target)
    end

    it 'raises if the shorthand block has the wrong arity' do
      expect {
        make_test_host(:HostD) do
          schedule 'Bad', '*/5 * * * *' do
            # arity 0 with an expression — invalid for shorthand
          end
        end
      }.to raise_error(ArgumentError, /requires a block of arity 1/)
    end
  end

  describe 'multi-step block form (auto-generated step classes)' do
    it 'generates one class per step under <Host>::Schedules and registers each with Sidereal.scheduler' do
      host = make_test_host(:HostA) do
        schedule 'Tick campaign' do
          at '2026-05-06T15:00:00' do |_cmd| end
          at 'every 3 seconds'    do |_cmd| end
          at '30s'                do |_cmd| end
        end
      end

      expect(host::Schedules.const_defined?(:SchedTickCampaign0Step0, false)).to be true
      expect(host::Schedules.const_defined?(:SchedTickCampaign0Step1, false)).to be true
      expect(host::Schedules.const_defined?(:SchedTickCampaign0Step2, false)).to be true

      step0 = host::Schedules::SchedTickCampaign0Step0
      expect(step0.type).to eq('host_a.schedules.tick_campaign_0_step_0')

      sch = Sidereal.scheduler.schedules.first
      expect(sch.name).to eq('Tick campaign')
      expect(sch.steps.map(&:klass)).to eq([
        host::Schedules::SchedTickCampaign0Step0,
        host::Schedules::SchedTickCampaign0Step1,
        host::Schedules::SchedTickCampaign0Step2
      ])
    end

    it 'records each step block on the host as the handler for its generated class' do
      host = make_test_host(:HostB) do
        schedule 'Three' do
          at '2026-05-04T10:00:00' do |_cmd| end
          at 'every minute'        do |_cmd| end
          at '5m'                  do |_cmd| end
        end
      end

      [:SchedThree0Step0, :SchedThree0Step1, :SchedThree0Step2].each do |const|
        klass = host::Schedules.const_get(const)
        expect(host.commands_registered[klass]).to be_a(Proc)
      end
    end
  end

  describe 'explicit-class form (klass + payload, no block)' do
    it 'passes the user-supplied class through to the Scheduler without generating a class or handler' do
      host = make_test_host(:HostA) do
        schedule 'Flash sale campaign' do
          at '2026-05-10T10:00:00', TestSchedulingTick, n: 1
          at 'every day at 9am',    TestSchedulingTick, n: 2
          at '10d',                 TestSchedulingExit
        end
      end

      expect(host::Schedules.constants).to be_empty
      expect(host.commands_registered).to be_empty

      sch = Sidereal.scheduler.schedules.first
      expect(sch.steps.size).to eq(3)
      expect(sch.steps[0].klass).to eq(TestSchedulingTick)
      expect(sch.steps[0].payload).to eq(n: 1)
      expect(sch.steps[2].klass).to eq(TestSchedulingExit)
      expect(sch.steps[2].payload).to eq({})
    end

    it 'allows mixing block and explicit forms across steps' do
      host = make_test_host(:HostB) do
        schedule 'Mixed' do
          at '2026-05-10T10:00:00' do |_cmd| end                # generated
          at 'every minute', TestSchedulingTick, n: 1           # explicit
          at '1h',           TestSchedulingExit                 # explicit
        end
      end

      expect(host::Schedules.const_defined?(:SchedMixed0Step0, false)).to be true
      expect(host::Schedules.const_defined?(:SchedMixed0Step1, false)).to be false
      expect(host::Schedules.const_defined?(:SchedMixed0Step2, false)).to be false

      sch = Sidereal.scheduler.schedules.first
      expect(sch.steps[1].klass).to eq(TestSchedulingTick)
      expect(sch.steps[2].klass).to eq(TestSchedulingExit)
    end

    it 'raises when both a block and a class are supplied to the same at' do
      expect {
        make_test_host(:HostC) do
          schedule 'Both' do
            at 'every minute', TestSchedulingTick, n: 1 do |_cmd| end
          end
        end
      }.to raise_error(ArgumentError, /pass either a block or a command class, not both/)
    end

    it 'a recurring step with neither a block nor a class raises (bound-only recurring is meaningless)' do
      expect {
        make_test_host(:HostD) do
          schedule 'BadMarker' do
            at 'every minute'
          end
        end
      }.to raise_error(ArgumentError, /recurring step.*requires a command class/)
    end

    it 'a specific or duration step with no class is a bound-only marker (anchors the timeline, never dispatches)' do
      host = make_test_host(:HostA) do
        schedule 'Campaign' do
          at '2026-05-04T10:00:00'                          # marker — no class
          at '*/5 * * * *', TestSchedulingTick, n: 1        # recurring anchored to the marker
        end
      end

      expect(host::Schedules.constants).to be_empty

      sch = Sidereal.scheduler.schedules.first
      expect(sch.steps[0].klass).to be_nil
      expect(sch.steps[0].at).to eq(Time.parse('2026-05-04T10:00:00'))
      expect(sch.steps[1].klass).to eq(TestSchedulingTick)
      expect(sch.steps[1].from).to eq(Time.parse('2026-05-04T10:00:00'))
    end
  end

  describe 'validation' do
    it 'raises if the schedule block has no at calls' do
      expect {
        make_test_host(:HostA) do
          schedule 'Empty' do
            # no at(...) calls
          end
        end
      }.to raise_error(ArgumentError, /must declare at least one at/)
    end

    it 'raises if the multi-step block takes arguments (must use the inner DSL)' do
      expect {
        make_test_host(:HostB) do
          schedule 'Bad' do |_cmd|
          end
        end
      }.to raise_error(ArgumentError, /block must take no arguments/)
    end

    it 'raises if the schedule name is nil or empty' do
      expect {
        make_test_host(:HostC) do
          schedule '' do
            at 'every minute', TestSchedulingTick, n: 1
          end
        end
      }.to raise_error(ArgumentError, /name is required/)
    end

    it 'survives a schedule name that starts with a digit (Sched prefix keeps the constant valid)' do
      host = make_test_host(:HostF) do
        schedule '5 minute' do
          at '*/5 * * * *' do |_cmd| end
        end
      end

      expect(host::Schedules.const_defined?(:Sched5Minute0Step0, false)).to be true
    end
  end
end
