# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::Exceptions do
  subject(:exceptions) { described_class.new }

  let(:cmd_class) do
    Sidereal::Message.define('exceptions_spec.cmd') do
      attribute :title, Sidereal::Types::String
    end
  end
  let(:cmd) { cmd_class.new(payload: { title: 'doomed' }) }
  let(:boom) do
    err = RuntimeError.new('boom')
    err.set_backtrace(['line1', 'line2'])
    err
  end

  describe 'subscriber registration' do
    it 'fires registered on_retry subscribers in registration order' do
      seen = []
      exceptions.on_retry { |r| seen << [:first, r.exception.message] }
      exceptions.on_retry { |r| seen << [:second, r.exception.message] }

      exceptions.report_retry(exception: boom, message: cmd, retry_count: 1, retry_at: Time.now + 60)

      expect(seen).to eq([[:first, 'boom'], [:second, 'boom']])
    end

    it 'fires registered on_failure subscribers' do
      seen = []
      exceptions.on_failure { |r| seen << r.exception }

      exceptions.report_failure(exception: boom, message: cmd, retry_count: 3)

      expect(seen).to eq([boom])
    end

    it 'on_retry / on_failure are independent — only the matching kind fires' do
      retry_calls = 0
      fail_count = 0
      exceptions.on_retry   { |_| retry_calls += 1 }
      exceptions.on_failure { |_| fail_count  += 1 }

      exceptions.report_retry(exception: boom, message: cmd, retry_count: 1, retry_at: Time.now + 60)

      expect(retry_calls).to eq(1)
      expect(fail_count).to eq(0)
    end

    it 'raises ArgumentError without a block' do
      expect { exceptions.on_retry }.to raise_error(ArgumentError, /block required/)
      expect { exceptions.on_failure }.to raise_error(ArgumentError, /block required/)
    end

    it 'an exception in one subscriber does not prevent later ones from firing' do
      after = false
      exceptions.on_failure { |_| raise 'subscriber broken' }
      exceptions.on_failure { |_| after = true }

      expect {
        exceptions.report_failure(exception: boom, message: cmd, retry_count: 1)
      }.not_to raise_error
      expect(after).to be(true)
    end
  end

  describe 'fatal channel (on_fatal)' do
    it 'routes a raising subscriber to on_fatal with the original report attached' do
      fatals = []
      exceptions.on_fatal { |f| fatals << f }
      resolver_bug = KeyError.new('no such attribute')
      exceptions.on_failure { |_| raise resolver_bug }

      exceptions.report_failure(exception: boom, message: cmd, retry_count: 2)

      expect(fatals.size).to eq(1)
      expect(fatals.first).to be_a(Sidereal::FatalReport)
      expect(fatals.first.exception).to be(resolver_bug)
      # the failure report being delivered when the subscriber blew up
      expect(fatals.first.report.failure?).to be(true)
      expect(fatals.first.report.message).to be(cmd)
    end

    it 'report_fatal fans out to on_fatal subscribers (no report context)' do
      seen = []
      exceptions.on_fatal { |f| seen << f }

      exceptions.report_fatal(exception: boom)

      expect(seen.size).to eq(1)
      expect(seen.first.exception).to be(boom)
      expect(seen.first.report).to be_nil
    end

    it 'never silently swallows: report_fatal works with zero subscribers (logs only)' do
      expect { exceptions.report_fatal(exception: boom) }.not_to raise_error
    end

    it 'an on_fatal subscriber that itself raises does not recurse or propagate' do
      reached_second = false
      exceptions.on_fatal { |_| raise 'fatal subscriber broken' }
      exceptions.on_fatal { |_| reached_second = true }

      expect { exceptions.report_fatal(exception: boom) }.not_to raise_error
      expect(reached_second).to be(true)
    end
  end

  describe 'ExceptionReport shape' do
    it 'wraps retry context and exposes #retry?' do
      retry_at = Time.now + 30
      received = nil
      exceptions.on_retry { |r| received = r }

      exceptions.report_retry(exception: boom, message: cmd, retry_count: 2, retry_at: retry_at)

      expect(received).to be_a(Sidereal::ExceptionReport)
      expect(received).to be_retry
      expect(received).not_to be_failure
      expect(received.kind).to eq(:retry)
      expect(received.exception).to eq(boom)
      expect(received.message).to eq(cmd)
      expect(received.retry_count).to eq(2)
      expect(received.retry_at).to eq(retry_at)
    end

    it 'wraps failure context with retry_at = nil and exposes #failure?' do
      received = nil
      exceptions.on_failure { |r| received = r }

      exceptions.report_failure(exception: boom, message: cmd, retry_count: 5)

      expect(received).to be_failure
      expect(received).not_to be_retry
      expect(received.retry_at).to be_nil
    end
  end

  describe '#lock!' do
    it 'is idempotent and reports state via #locked?' do
      expect(exceptions.locked?).to be(false)
      exceptions.lock!
      expect(exceptions.locked?).to be(true)
      expect { exceptions.lock! }.not_to raise_error
    end

    it 'raises LockedError on subsequent on_retry / on_failure / on_fatal registration' do
      exceptions.lock!

      expect { exceptions.on_retry   { |_| } }.to raise_error(Sidereal::Exceptions::LockedError, /locked/)
      expect { exceptions.on_failure { |_| } }.to raise_error(Sidereal::Exceptions::LockedError, /locked/)
      expect { exceptions.on_fatal   { |_| } }.to raise_error(Sidereal::Exceptions::LockedError, /locked/)
    end

    it 'still allows reports to fan out after lock' do
      seen = []
      exceptions.on_failure { |r| seen << r }
      exceptions.lock!

      exceptions.report_failure(exception: boom, message: cmd, retry_count: 1)

      expect(seen.size).to eq(1)
    end
  end

  describe '#reset!' do
    it 'clears subscribers and unlocks' do
      exceptions.on_retry { |_| }
      exceptions.lock!
      exceptions.reset!

      expect(exceptions.locked?).to be(false)
      # Subscribers cleared — no fan-out happens.
      expect { exceptions.report_retry(exception: boom, message: cmd, retry_count: 1, retry_at: Time.now) }.not_to raise_error
    end
  end

  describe '.with_default_publisher (the toast publisher pair)' do
    let(:pubsub) { Sidereal::PubSub::Memory.new }
    let(:channels) do
      Sidereal::Channels.with_system_defaults.tap do |c|
        c.channel_name(cmd_class) { |msg| "ch.#{msg.payload.title}" }
      end
    end

    around do |ex|
      original_channels_var = Sidereal.instance_variable_get(:@channels)
      Sidereal.reset_config!
      Sidereal.config.pubsub = pubsub
      Sidereal.instance_variable_set(:@channels, channels)
      ex.run
    ensure
      Sidereal.reset_config!
      Sidereal.instance_variable_set(:@channels, original_channels_var)
    end

    def collect_published(channel_name)
      received = []
      Sync do |task|
        ch = pubsub.subscribe(channel_name)
        task.async { ch.start { |msg, _| received << msg } }
        task.async do
          yield
          sleep 0.02
          ch.stop
          task.stop
        end.wait
      end
      received
    end

    it 'publishes a NotifyRetry on the failed message channel for retry reports' do
      reg = described_class.with_default_publisher

      received = collect_published('ch.doomed') do
        reg.report_retry(exception: boom, message: cmd, retry_count: 1, retry_at: Time.now + 60)
      end

      expect(received.size).to eq(1)
      expect(received.first).to be_a(Sidereal::System::NotifyRetry)
      expect(received.first.payload.command_type).to eq(cmd_class.type)
      expect(received.first.payload.command_id).to eq(cmd.id)
      expect(received.first.payload.error_message).to eq('boom')
    end

    it 'publishes a NotifyFailure on the failed message channel for failure reports' do
      reg = described_class.with_default_publisher

      received = collect_published('ch.doomed') do
        reg.report_failure(exception: boom, message: cmd, retry_count: 3)
      end

      expect(received.size).to eq(1)
      expect(received.first).to be_a(Sidereal::System::NotifyFailure)
      expect(received.first.payload.retry_count).to eq(3)
    end

    it 'a domain-specific channel resolver only ever sees the failed user command, not the notification' do
      # The default publisher publishes on Sidereal.channels.for(report.message),
      # which is the user resolver — fine. The failed message is the
      # user command, not the system notification, so the domain
      # resolver receives only the user command.
      reg = described_class.with_default_publisher

      expect {
        reg.report_failure(exception: boom, message: cmd, retry_count: 1)
      }.not_to raise_error
    end
  end
end
