# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'socket'
require 'console'
require_relative 'pattern'

module Sidereal
  module PubSub
    # Unix-domain-socket pubsub for cross-process delivery on a single host.
    #
    # Topology: embedded leader. The first process to acquire a +flock+ on
    # +lock_path+ binds +socket_path+ and runs an in-process broker fiber
    # that fans out frames to every connected peer. Other processes
    # +connect+ as plain clients. When the leader dies, the kernel closes
    # its listening socket; clients see EOF and re-run election +
    # connection inside their reconnect-with-backoff loop. +flock+ is
    # auto-released on process death — no stale-lock cleanup required.
    #
    # Wire format: newline-delimited JSON, one frame type:
    #
    #   {"channel": "<name>", "msg": <Message#to_h with iso8601 Times>}\n
    #
    # Wildcard matching is performed on the receiving client (the broker
    # is a dumb fan-out). Failover therefore requires no re-subscription —
    # the broker holds zero per-client state.
    #
    # Public contract is identical to {PubSub::Memory}.
    class Unix
      DEFAULT_SOCKET = 'tmp/sidereal-pubsub.sock'
      DEFAULT_LOCK   = 'tmp/sidereal-pubsub.lock'
      DEFAULT_WRITE_QUEUE = 1_000

      # macOS sockaddr_un.sun_path is 104 bytes; Linux is 108. Use the smaller.
      SOCKET_PATH_MAX = 104

      def initialize(
        socket_path: DEFAULT_SOCKET,
        lock_path: DEFAULT_LOCK,
        reconnect_min: 0.05,
        reconnect_max: 0.5,
        write_queue_size: DEFAULT_WRITE_QUEUE
      )
        @socket_path = File.expand_path(socket_path)
        @lock_path = File.expand_path(lock_path)
        validate_socket_path!(@socket_path)

        @reconnect_min = reconnect_min
        @reconnect_max = reconnect_max
        @write_queue_size = write_queue_size

        FileUtils.mkdir_p(File.dirname(@socket_path))
        FileUtils.mkdir_p(File.dirname(@lock_path))

        @mutex = Mutex.new
        @subscribers = {}
        @wildcards = []

        @peers_mutex = Mutex.new
        @peers = {}

        @send_mutex = Mutex.new
        @client_socket = nil
        @leader_lock_io = nil
        @server = nil
        @broker_task = nil

        @started = false
      end

      # Whether this process currently holds the broker role — i.e. has won
      # the +flock+ election and bound the listening socket. While +true+,
      # this process is fanning out frames to every connected peer. Flips
      # back to +false+ when the broker is torn down (clean shutdown or a
      # detected EOF triggering reconnect).
      # @return [Boolean]
      def leader?
        !@server.nil?
      end

      # Lifecycle hook. Idempotent; safe to call from any caller before any
      # publish or subscribe. Spawns a single +run_client+ fiber as a
      # transient child of +task+; that fiber handles election (via
      # +flock+), broker setup (when elected), and the read loop, with
      # automatic reconnect on EOF or error.
      def start(task)
        @mutex.synchronize do
          return self if @started
          @started = true
        end

        task.async(transient: true) { run_client(task) }
        self
      end

      # @param pattern [String] exact channel name or wildcard pattern
      # @return [Channel]
      def subscribe(pattern)
        Pattern.validate_subscription!(pattern)
        ensure_started
        channel = Channel.new(name: pattern, pubsub: self)
        @mutex.synchronize do
          if Pattern.wildcard?(pattern)
            @wildcards = @wildcards + [[Pattern.compile(pattern), channel]]
          else
            @subscribers[pattern] = (@subscribers[pattern] || []) + [channel]
          end
        end
        channel
      end

      # Remove a channel from the subscriber list. Local-only — the broker
      # holds no subscription state.
      # @param channel [Channel]
      def unsubscribe(channel)
        @mutex.synchronize do
          if Pattern.wildcard?(channel.name)
            @wildcards = @wildcards.reject { |_re, ch| ch.equal?(channel) }
          else
            arr = @subscribers[channel.name]
            @subscribers[channel.name] = arr - [channel] if arr
          end
        end
      end

      # Deliver synchronously to local subscribers, then write the frame
      # to the leader's broker. The broker fans out to every other
      # connected peer (excluding the originator, which already received
      # the message via the local path). If we're disconnected from the
      # broker — e.g. mid-failover — the wire publish is dropped with a
      # warning; local subscribers still receive their copy.
      #
      # @param channel_name [String]
      # @param event [Sidereal::Message]
      # @return [self]
      def publish(channel_name, event)
        Pattern.validate_publish!(channel_name)
        ensure_started

        deliver_local(channel_name, event)

        frame = encode_frame(channel_name, event)
        @send_mutex.synchronize do
          socket = @client_socket
          if socket
            begin
              socket.write(frame)
            rescue Errno::EPIPE, Errno::ECONNRESET, IOError => ex
              Console.warn(self, 'publish dropped: socket disconnected', exception: ex)
            end
          end
        end

        self
      end

      class Channel
        attr_reader :name

        def initialize(name:, pubsub:)
          @name = name
          @pubsub = pubsub
          @queue = Async::Queue.new
        end

        def <<(message)
          @queue << message
          self
        end

        def start(handler: nil, &block)
          handler ||= block
          while (msg = @queue.pop)
            handler.call(msg, self)
          end
          self
        end

        def stop
          @pubsub.unsubscribe(self)
          @queue << nil
          self
        end
      end

      private

      def ensure_started
        return if @started

        task = Async::Task.current?
        return unless task

        # Walk up to the topmost (root) task so the run_client fiber outlives
        # any short-lived per-request ancestor (e.g. an SSE handler fiber).
        # Async::Task#parent returns nil at the root.
        task = task.parent while task.parent

        start(task)
      end

      # Local-only fanout. Mirrors {Memory#publish}.
      def deliver_local(channel_name, event)
        targets = @mutex.synchronize do
          list = []
          list.concat(@subscribers[channel_name]) if @subscribers[channel_name]
          @wildcards.each { |re, ch| list << ch if re.match?(channel_name) }
          list
        end
        targets.each { |ch| ch << event }
      end

      def encode_frame(channel_name, event)
        attrs = event.to_h
        attrs.each do |k, v|
          attrs[k] = v.iso8601(6) if v.is_a?(Time)
        end
        JSON.dump(channel: channel_name, msg: attrs) + "\n"
      end

      def decode_frame(line)
        parsed = JSON.parse(line, symbolize_names: true)
        [parsed[:channel], Sidereal::Message.from(parsed[:msg])]
      end

      def validate_socket_path!(path)
        if path.bytesize >= SOCKET_PATH_MAX
          raise ArgumentError,
                "socket path is too long (#{path.bytesize} bytes; max #{SOCKET_PATH_MAX - 1}): #{path.inspect}"
        end
      end

      # Try to acquire the leader flock. On success, store the open file
      # in @leader_lock_io (closing it releases the lock).
      # @return [Boolean]
      def try_become_leader
        io = File.open(@lock_path, File::RDWR | File::CREAT, 0o644)
        if io.flock(File::LOCK_EX | File::LOCK_NB)
          @leader_lock_io = io
          true
        else
          io.close
          false
        end
      end

      # Combined election + connection + read loop with reconnect-with-
      # backoff. Every iteration re-runs election: when the prior leader
      # dies, every connected client lands here and races for flock.
      def run_client(task)
        loop do
          run_one_connection(task)
        rescue StandardError => ex
          Console.warn(self, 'pubsub client iteration error', exception: ex)
        ensure
          tear_down_connection
          sleep(rand_backoff)
        end
      end

      def run_one_connection(task)
        if try_become_leader
          # Replace any stale socket from a dead prior leader.
          File.unlink(@socket_path) if File.exist?(@socket_path)
          @server = UNIXServer.new(@socket_path)
          @broker_task = task.async(transient: true) { run_broker(task) }
          Console.info(self, "pubsub: elected as broker", pid: Process.pid, socket: @socket_path)
        else
          Console.info(self, "pubsub: connecting as client", pid: Process.pid, socket: @socket_path)
        end

        @client_socket = UNIXSocket.new(@socket_path)

        @client_socket.each_line do |line|
          begin
            channel_name, event = decode_frame(line)
            deliver_local(channel_name, event) if channel_name && event
          rescue StandardError => ex
            Console.error(self, 'pubsub frame decode failed', exception: ex, line: line)
          end
        end
      end

      def tear_down_connection
        if (sock = @client_socket)
          @client_socket = nil
          sock.close rescue nil
        end

        if (broker = @broker_task)
          @broker_task = nil
          broker.stop
        end

        if (srv = @server)
          @server = nil
          srv.close rescue nil
        end

        if (lock = @leader_lock_io)
          @leader_lock_io = nil
          lock.close rescue nil
          Console.info(self, "pubsub: stepped down as broker", pid: Process.pid)
        end

        @peers_mutex.synchronize do
          @peers.each_key { |peer| peer.close rescue nil }
          @peers.clear
        end
      end

      def rand_backoff
        @reconnect_min + (rand * (@reconnect_max - @reconnect_min))
      end

      # Broker (leader-only) accept loop. Each peer gets a writer fiber
      # draining a per-peer LimitedQueue and a reader fiber that fans
      # received frames out to every other peer.
      def run_broker(task)
        loop do
          peer = @server.accept
          register_peer(task, peer)
        end
      rescue IOError, Errno::EBADF
        # Server closed — leader is shutting down; exit cleanly.
      end

      def register_peer(task, peer)
        write_queue = Async::LimitedQueue.new(@write_queue_size)
        @peers_mutex.synchronize { @peers[peer] = write_queue }

        # Writer fiber: drain queue → write to peer.
        task.async(transient: true) do
          while (line = write_queue.pop)
            peer.write(line)
          end
        rescue StandardError => ex
          Console.warn(self, 'broker peer writer failed', exception: ex)
        ensure
          drop_peer(peer)
        end

        # Reader fiber: each_line → fan out to every other peer.
        task.async(transient: true) do
          peer.each_line { |line| fan_out(line, except: peer) }
        rescue StandardError => ex
          Console.warn(self, 'broker peer reader failed', exception: ex)
        ensure
          drop_peer(peer)
        end
      end

      def fan_out(line, except:)
        slow_peers = []
        @peers_mutex.synchronize do
          @peers.each do |peer, queue|
            next if peer.equal?(except)
            if queue.size >= @write_queue_size
              slow_peers << peer
            else
              queue << line
            end
          end
        end
        slow_peers.each do |peer|
          Console.warn(self, 'dropping slow peer', peer: peer.inspect)
          drop_peer(peer)
        end
      end

      def drop_peer(peer)
        queue = nil
        @peers_mutex.synchronize do
          queue = @peers.delete(peer)
        end
        # Unblock the writer fiber if it's waiting.
        queue << nil if queue
        peer.close rescue nil
      end
    end
  end
end
