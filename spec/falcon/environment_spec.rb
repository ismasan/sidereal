# frozen_string_literal: true

require 'spec_helper'
require 'sidereal/falcon/environment'

RSpec.describe Sidereal::Falcon::Environment::Service do
  # Records terminations instead of exiting, so the failure paths of #run can be
  # driven in-process. Everything else is the real service.
  class RecordingService < described_class
    attr_reader :terminations

    def initialize(...)
      super
      @terminations = []
    end

    def terminate_host!(status)
      @terminations << status
      :terminated # #run returns this, standing in for the process ending
    end
  end

  # The service reads only `name` off the environment (for log subjects), and
  # takes the evaluator and the bound listener it uses as arguments to #run.
  let(:environment) { double('environment', evaluator: evaluator, name: 'test-service') }
  let(:evaluator) { double('evaluator', name: 'test-service', count: 1) }
  let(:instance) { double('instance') }
  let(:listener) { double('listener', endpoint: double('bound endpoint')) }
  let(:service) { RecordingService.new(environment, evaluator) }

  describe 'a boot failure' do
    before { allow(Console).to receive(:error) }

    it 'terminates the host instead of returning into the restart loop' do
      allow(evaluator).to receive(:make_server).and_raise(NoMethodError, 'undefined method for nil')

      expect(service.run(instance, evaluator, listener)).to eq(:terminated)
      expect(service.terminations).to eq([1])
    end

    it 'logs the exception, so the failure is not left to Async task warnings' do
      error = NoMethodError.new('undefined method for nil')
      allow(evaluator).to receive(:make_server).and_raise(error)

      expect(Console).to receive(:error) do |_subject, message, **meta|
        expect(message).to include('failed to boot')
        expect(meta[:exception]).to be(error)
      end

      service.run(instance, evaluator, listener)
    end

    it 'reports a boot error that is not a StandardError' do
      allow(evaluator).to receive(:make_server).and_raise(NotImplementedError, 'nope')

      expect(Console).to receive(:error)
      expect(service.run(instance, evaluator, listener)).to eq(:terminated)
    end

    it 'widens an exit requested by a boot check to the whole host' do
      # Sidereal.check_topology! logs its own diagnosis and exits; the exit
      # status is carried through rather than relabelled.
      allow(evaluator).to receive(:make_server).and_raise(SystemExit.new(2))

      expect(Console).not_to receive(:error)
      expect(service.run(instance, evaluator, listener)).to eq(:terminated)
      expect(service.terminations).to eq([2])
    end

    it 'terminates when a subsystem fails to start inside the async task' do
      # Reached after #run returns, so this failure has no rescue above it in
      # the call stack — only the guard inside the task itself.
      error = Errno::EADDRINUSE.new('pubsub socket')
      server = double('server')
      allow(server).to receive(:run).and_raise(error)
      allow(evaluator).to receive(:make_server).and_return(server)

      expect(Console).to receive(:error) do |_subject, _message, **meta|
        expect(meta[:exception]).to be(error)
      end

      service.run(instance, evaluator, listener)
      expect(service.terminations).to eq([1])
    end

    it 'lets a shutdown signal through untouched' do
      allow(evaluator).to receive(:make_server).and_raise(Interrupt)

      expect { service.run(instance, evaluator, listener) }.to raise_error(Interrupt)
      expect(service.terminations).to be_empty
    end
  end
end
