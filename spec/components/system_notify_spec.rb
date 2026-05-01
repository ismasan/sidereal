# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::Components::SystemNotify do
  def retry_msg
    Sidereal::System::NotifyRetry.new(payload: {
      command_type: 'todos.add',
      command_id: SecureRandom.uuid,
      command_payload: { title: 'buy milk' },
      attempt: 2,
      retry_at: '2026-05-01T11:30:00+00:00',
      error_class: 'RuntimeError',
      error_message: 'transient failure',
      backtrace: ['app.rb:90 in `do_thing`', 'lib/x.rb:1']
    })
  end

  def failure_msg(backtrace: [])
    Sidereal::System::NotifyFailure.new(payload: {
      command_type: 'todos.add',
      command_id: SecureRandom.uuid,
      command_payload: { title: 'buy milk' },
      attempt: 5,
      error_class: 'RuntimeError',
      error_message: 'permanent failure',
      backtrace: backtrace
    })
  end

  describe Sidereal::Components::SystemNotifyRetry do
    let(:html) { described_class.new(retry_msg).call }

    it 'renders the retry kind class' do
      expect(html).to include('sidereal-sysnotify--retry')
    end

    it 'includes a self-contained <style> tag' do
      expect(html).to match(%r{<style>.*\.sidereal-sysnotify.*</style>}m)
    end

    it 'includes the command type and attempt in the title' do
      expect(html).to include('todos.add')
      expect(html).to include('attempt 2')
    end

    it 'includes the error class and message' do
      expect(html).to include('RuntimeError')
      expect(html).to include('transient failure')
    end

    it 'includes the retry_at timestamp' do
      expect(html).to include('2026-05-01T11:30:00+00:00')
    end

    it 'includes the backtrace inside a collapsible details element' do
      expect(html).to include('<details')
      expect(html).to include('app.rb:90 in `do_thing`')
    end

    it 'tags the toast div with the message id for predictable morph' do
      msg = retry_msg
      expect(described_class.new(msg).call).to include(%(id="sidereal-sysnotify-#{msg.id}"))
    end
  end

  describe Sidereal::Components::SystemNotifyFailure do
    let(:html) { described_class.new(failure_msg).call }

    it 'renders the failure kind class' do
      expect(html).to include('sidereal-sysnotify--failure')
    end

    it 'mentions the attempt count' do
      expect(html).to include('5 attempt')
    end

    it 'includes the error message' do
      expect(html).to include('permanent failure')
    end

    it 'omits the backtrace section when backtrace is empty' do
      html = described_class.new(failure_msg(backtrace: [])).call
      expect(html).not_to include('<details')
    end

    it 'includes the backtrace section when backtrace is non-empty' do
      html = described_class.new(failure_msg(backtrace: ['x.rb:1', 'y.rb:2'])).call
      expect(html).to include('<details')
      expect(html).to include('x.rb:1')
      expect(html).to include('y.rb:2')
    end
  end
end
