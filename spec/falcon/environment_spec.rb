# frozen_string_literal: true

require 'spec_helper'
require 'sidereal/falcon/environment'
require 'tmpdir'
require 'fileutils'

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

  describe '#start, in the process that forks the workers' do
    let(:root) { Dir.mktmpdir }
    # Falcon's Server#start binds the endpoint before anything else: a free
    # local port, released by #stop.
    let(:endpoint) { Async::HTTP::Endpoint.parse('http://127.0.0.1:0') }
    let(:evaluator) { double('evaluator', name: 'test-service', count: 1, root:, preload:, endpoint:) }

    after do
      service.stop
      FileUtils.rm_rf(root)
    end

    context 'when it preloads the app' do
      let(:preload) { ['boot.rb'] }

      let(:boot) { "Sidereal.config.declare('db') { PRELOAD_LOG << :built }\n" }

      before do
        File.write(File.join(root, 'boot.rb'), boot)
        stub_const('PRELOAD_LOG', [])
      end

      it "loads the app's components there, for every worker to share, and builds none" do
        service.start

        expect(Sidereal.config).to be_declared('db')
        expect(PRELOAD_LOG).to be_empty
      end

      it 'refuses to build there' do
        service.start

        expect { Sidereal.config.build! }.to raise_error(Sidereal::ForkError)
      end

      context 'and the app builds the config while it loads' do
        let(:boot) { super() + "Sidereal.config.build!\n" }

        it 'fails to start instead of handing every worker the same values' do
          expect { service.start }.to raise_error(Sidereal::ForkError, /can't be built in process/)
          expect(PRELOAD_LOG).to be_empty
        end
      end
    end

    context 'when each worker loads the app' do
      let(:preload) { [] }

      it 'leaves the config for the worker to declare into and build' do
        service.start

        expect { Sidereal.config.declare('db') { :db } }.not_to raise_error
        expect(Sidereal.config.boot_status).to eq(:open)
      end
    end
  end

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

    # Async stops a task by raising Async::Cancel in it (an Exception, not a
    # SignalException): an interrupt that lands while the host is still booting
    # is a shutdown, and must reach the orderly #stop path, not boot_failed!.
    it 'lets a cancellation during boot inside the async task through, as a shutdown' do
      server = double('server')
      allow(server).to receive(:run).and_raise(Async::Cancel)
      allow(evaluator).to receive(:make_server).and_return(server)

      expect(Console).not_to receive(:error)
      service.run(instance, evaluator, listener)
      expect(service.terminations).to be_empty
    end

    it 'lets a cancellation while loading the app through untouched' do
      allow(evaluator).to receive(:make_server).and_raise(Async::Cancel)

      expect(Console).not_to receive(:error)
      expect { service.run(instance, evaluator, listener) }.to raise_error(Async::Cancel)
      expect(service.terminations).to be_empty
    end

    it 'lets a shutdown signal through untouched' do
      allow(evaluator).to receive(:make_server).and_raise(Interrupt)

      expect { service.run(instance, evaluator, listener) }.to raise_error(Interrupt)
      expect(service.terminations).to be_empty
    end
  end
end
