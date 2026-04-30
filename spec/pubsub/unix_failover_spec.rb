# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'tmpdir'
require 'json'
require 'sidereal/pubsub/unix'

UnixFailoverMsg = Sidereal::Message.define('unix_failover_spec.event') do
  attribute :tag, Sidereal::Types::String
end

RSpec.describe 'Sidereal::PubSub::Unix cross-process' do
  around(:each) do |example|
    # Use /tmp directly so socket paths fit inside the 104-byte sun_path limit
    # (macOS's default tmpdir under /var/folders/... is too long).
    Dir.mktmpdir(['srl-', ''], '/tmp') do |root|
      @root = root
      example.run
    end
  end

  def socket_path = File.join(@root, 'pubsub.sock')
  def lock_path = File.join(@root, 'pubsub.lock')

  def build_pubsub
    Sidereal::PubSub::Unix.new(
      socket_path: socket_path,
      lock_path: lock_path,
      reconnect_min: 0.02,
      reconnect_max: 0.05
    )
  end

  describe 'fan-out across two processes' do
    it 'delivers messages from a publisher to a subscriber in another process' do
      received_path = File.join(@root, 'received.json')
      ready_path = File.join(@root, 'subscriber_ready')

      child_pid = fork do
        # Child: become leader (run first), subscribe, collect a few messages.
        pubsub = build_pubsub
        received = []
        Sync do |task|
          pubsub.start(task)
          channel = pubsub.subscribe('events.>')
          collector = task.async do
            channel.start { |m, _| received << m.payload.tag }
          end

          # Wait until our broker is up before signalling readiness.
          sleep 0.05 until pubsub.leader?
          File.write(ready_path, '1')

          deadline = Time.now + 3.0
          sleep 0.02 until received.size >= 3 || Time.now > deadline
          channel.stop
          collector.wait
        end
        File.write(received_path, JSON.dump(received))
        exit!(0)
      end

      # Parent: wait for the child's broker to bind, then connect and publish.
      deadline = Time.now + 3.0
      sleep 0.02 until File.exist?(ready_path) || Time.now > deadline
      raise 'child subscriber never signalled ready' unless File.exist?(ready_path)

      pubsub = build_pubsub
      Sync do |task|
        pubsub.start(task)
        # Allow a moment for the client connection to be accepted by the broker.
        sleep 0.1
        3.times { |i| pubsub.publish("events.#{i}", UnixFailoverMsg.new(payload: { tag: i.to_s })) }
        # Allow time for frames to traverse the wire before exiting Sync.
        sleep 0.3
        task.stop
      end

      Process.wait(child_pid)
      received = JSON.parse(File.read(received_path))
      expect(received.sort).to eq(%w[0 1 2])
    end
  end

  describe 'leader election across three processes' do
    it 'elects exactly one leader' do
      results_dir = File.join(@root, 'leadership')
      FileUtils.mkdir_p(results_dir)

      pids = 3.times.map do |i|
        fork do
          pubsub = build_pubsub
          Sync do |task|
            pubsub.start(task)
            sleep 0.3 # let election settle
            File.write(File.join(results_dir, "#{i}.txt"), pubsub.leader?.to_s)
            task.stop
          end
          exit!(0)
        end
      end

      pids.each { |pid| Process.wait(pid) }

      results = Dir.children(results_dir).map { |f| File.read(File.join(results_dir, f)) }
      expect(results.count('true')).to eq(1)
      expect(results.count('false')).to eq(2)
    end
  end

  describe 'failover when the leader dies' do
    it 'promotes a survivor and resumes message flow' do
      # Process A: becomes leader, then SIGKILL'd by the parent.
      # Process B: starts as client, takes over leadership, subscribes,
      #            collects post-failover messages.
      received_path = File.join(@root, 'received.json')
      b_ready_path = File.join(@root, 'b_ready')

      a_pid = fork do
        pubsub = build_pubsub
        Sync do |task|
          pubsub.start(task)
          # Hold the leadership until killed.
          sleep
        end
        exit!(0)
      end

      # Wait for A to become leader.
      deadline = Time.now + 3.0
      sleep 0.02 until File.exist?(socket_path) || Time.now > deadline
      raise 'leader A never bound socket' unless File.exist?(socket_path)
      sleep 0.1 # let A's accept loop settle

      b_pid = fork do
        pubsub = build_pubsub
        received = []
        Sync do |task|
          pubsub.start(task)
          channel = pubsub.subscribe('after.>')
          collector = task.async do
            channel.start { |m, _| received << m.payload.tag }
          end

          # Wait until B has become leader (i.e. A has died and B has been promoted).
          sleep 0.05 until pubsub.leader?
          File.write(b_ready_path, '1')

          deadline = Time.now + 3.0
          sleep 0.02 until received.size >= 2 || Time.now > deadline
          channel.stop
          collector.wait
        end
        File.write(received_path, JSON.dump(received))
        exit!(0)
      end

      # Give B a moment to connect to A before killing A.
      sleep 0.3
      Process.kill('KILL', a_pid)
      Process.wait(a_pid)

      # Wait for B to have been promoted to leader.
      deadline = Time.now + 5.0
      sleep 0.05 until File.exist?(b_ready_path) || Time.now > deadline
      raise 'B never took over leadership' unless File.exist?(b_ready_path)

      # Publish from a third (fresh) process now that B is leader.
      publisher_pid = fork do
        pubsub = build_pubsub
        Sync do |task|
          pubsub.start(task)
          sleep 0.2 # let connection establish
          2.times { |i| pubsub.publish("after.#{i}", UnixFailoverMsg.new(payload: { tag: i.to_s })) }
          sleep 0.3
          task.stop
        end
        exit!(0)
      end

      Process.wait(publisher_pid)
      Process.wait(b_pid)

      received = JSON.parse(File.read(received_path))
      expect(received.sort).to eq(%w[0 1])
    end
  end

  describe 'publish without a connected broker' do
    it 'silently drops the wire send and does not raise' do
      # Outside an Async reactor, ensure_started is a no-op (no current task),
      # so the pubsub is never started and @client_socket is nil — the same
      # state a publisher would briefly observe between EOF and reconnect
      # during a failover. publish must tolerate it.
      pubsub = Sidereal::PubSub::Unix.new(
        socket_path: socket_path,
        lock_path: lock_path
      )
      expect do
        pubsub.publish('any.thing', UnixFailoverMsg.new(payload: { tag: 'lost' }))
      end.not_to raise_error
    end
  end
end
