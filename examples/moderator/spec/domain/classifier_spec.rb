# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Classifier do
  # Stands in for the consumer group. `on_exception`'s third argument is
  # documented as anything responding to #retry / #fail, which is all the
  # strategy touches.
  class FakeGroup
    attr_reader :calls, :error_context

    def initialize
      @calls = []
      @error_context = {}
    end

    def retry(at, **ctx)
      @calls << [:retry, at]
      @error_context.merge!(ctx)
    end

    def fail(exception:)
      @calls << [:fail, exception.class]
    end
  end

  let(:group) { FakeGroup.new }
  let(:message) do
    Comment::ModerationStarted.new(payload: { comment_id: SecureRandom.uuid, started_by: 'classifier' })
  end

  def api_error(klass, status) = klass.new('boom', status: status, body: '')

  describe 'retry policy' do
    # The HTTP client already retried these within its own budget, so reaching
    # here means waiting minutes is the only thing left to try.
    {
      'a rate limit' => -> { api_error(RubyDecisionModel::RateLimited, 429) },
      'an overloaded model' => -> { api_error(RubyDecisionModel::Overloaded, 503) },
      'a read timeout' => -> { RubyDecisionModel::TimeoutError.new('read timeout') },
      'a dropped connection' => -> { RubyDecisionModel::TransportError.new('reset') }
    }.each do |label, build|
      it "retries #{label}" do
        described_class.on_exception(instance_exec(&build), message, group)

        expect(group.calls.map(&:first)).to eq([:retry])
      end
    end

    # These fail identically however often they run, so burning four more
    # model calls to reach the same place helps nobody.
    {
      'a rejected key' => -> { api_error(RubyDecisionModel::Unauthorized, 401) },
      'an unusable payload' => -> { api_error(RubyDecisionModel::UnprocessableEntity, 422) },
      'a missing key' => -> { RubyDecisionModel::ConfigurationError.new('api_key is required') },
      'a judge that cannot answer' => -> { Feelings::JudgeError.new('no answer') },
      'a vibe with no branch' => -> { RuntimeError.new('no verdict for abc') }
    }.each do |label, build|
      it "stops the consumer group on #{label}" do
        described_class.on_exception(instance_exec(&build), message, group)

        expect(group.calls).to eq([[:fail, instance_exec(&build).class]])
      end
    end

    it 'backs off exponentially and gives up after four attempts' do
      started = Time.now
      5.times { described_class.on_exception(api_error(RubyDecisionModel::RateLimited, 429), message, group) }

      kinds = group.calls.map(&:first)
      delays = group.calls.take(4).map { |(_, at)| (at - started).round }

      expect(kinds).to eq(%i[retry retry retry retry fail])
      expect(delays).to eq([10, 20, 40, 80])
    end
  end
end
