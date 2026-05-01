# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'sidereal/store/file_system'

IntegrationCmd = Sidereal::Message.define('integration_spec.cmd') do
  attribute :name, Sidereal::Types::String
end

# Exercises the full retry → fail path end-to-end:
#   Dispatcher → FS store (with scheduler/poller fibers running) →
#   Commander whose handler always raises → default-shape on_error
#   policy → message ends up in dead/ after DEFAULT_MAX_ATTEMPTS.
#
# Uses a tight backoff override (0.05s) so the test converges in well
# under a second instead of the production default of 30s.
RSpec.describe 'Sidereal retry → fail integration' do
  around(:each) do |example|
    Dir.mktmpdir('sidereal-integration') do |root|
      @root = root
      example.run
    end
  end

  it 'retries up to DEFAULT_MAX_ATTEMPTS then dead-letters' do
    handler_calls = 0

    failing_commander = Class.new(Sidereal::Commander) do
      command IntegrationCmd do |_cmd|
        handler_calls += 1
        raise 'persistent failure'
      end

      # Same shape as the default policy but tighter backoff so the
      # test converges quickly.
      def self.on_error(exception, _message, meta)
        if meta.attempt < Sidereal::Commander::DEFAULT_MAX_ATTEMPTS
          Sidereal::Store::Result::Retry.new(at: Time.now + 0.05)
        else
          Sidereal::Store::Result::Fail.new(error: exception)
        end
      end
    end

    store = Sidereal::Store::FileSystem.new(
      root: @root,
      poll_interval: 0.01,
      scheduler_interval: 0.02,
      sweep_interval: 60
    )
    pubsub = Sidereal::PubSub::Memory.new

    registry = Sidereal::Registry.new
    registry[IntegrationCmd] = failing_commander

    Sync do |task|
      Sidereal::Dispatcher.new(
        worker_count: 1,
        store: store,
        registry: registry,
        pubsub: pubsub
      ).start(task)

      store.append(IntegrationCmd.new(payload: { name: 'doomed' }))

      task.async do
        deadline = Time.now + 3.0
        loop do
          break if Dir.children(File.join(@root, 'dead')).size == 2
          break if Time.now > deadline

          sleep 0.02
        end
        task.stop
      end.wait
    end

    expect(handler_calls).to eq(Sidereal::Commander::DEFAULT_MAX_ATTEMPTS)

    dead = Dir.children(File.join(@root, 'dead'))
    expect(dead.size).to eq(2)

    message_name = dead.find { |n| !n.end_with?('.error.json') }
    parts = Sidereal::Store::FileSystem.parse_filename(message_name)
    expect(parts[:attempt]).to eq(Sidereal::Commander::DEFAULT_MAX_ATTEMPTS)

    sidecar_name = dead.find { |n| n.end_with?('.error.json') }
    sidecar = JSON.parse(File.read(File.join(@root, 'dead', sidecar_name)))
    expect(sidecar['class']).to eq('RuntimeError')
    expect(sidecar['message']).to eq('persistent failure')

    expect(Dir.children(File.join(@root, 'ready'))).to be_empty
    expect(Dir.children(File.join(@root, 'scheduled'))).to be_empty
    expect(Dir.children(File.join(@root, 'processing'))).to be_empty
  end
end
