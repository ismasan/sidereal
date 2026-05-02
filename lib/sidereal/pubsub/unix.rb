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
    # Topology: embedded leader, election delegated to an injected
    # {Sidereal::Elector}. When the elector promotes this process,
    # Pubsub binds +socket_path+ and runs an in-process broker fiber
    # that fans out frames to every connected peer. Other processes
    # +connect+ as plain clients. When the leader dies, the elector
    # detects the vacancy and a successor is promoted; meanwhile,
    # clients see EOF and reconnect via the broker socket once the
    # new broker has bound it.
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
      DEFAULT_WRITE_QUEUE = 1_000

      # macOS sockaddr_un.sun_path is 104 bytes; Linux is 108. Use the smaller.
      SOCKET_PATH_MAX = 104

      def initialize(
        socket_path: DEFAULT_SOCKET,
        reconnect_min: 0.05,
        reconnect_max: 0.5,
        write_queue_size: DEFAULT_WRITE_QUEUE,
        elector: nil
      )
        @socket_path = File.expand_path(socket_path)
        validate_socket_path!(@socket_path)

        @reconnect_min = reconnect_min
        @reconnect_max = reconnect_max
        @write_queue_size = write_queue_size
        @elector = elector            # nil = resolve from Sidereal.elector at start time

        FileUtils.mkdir_p(File.dirname(@socket_path))

        @mutex = Mutex.new
        @subscribers = {}
        @wildcards = []

        @peers_mutex = Mutex.new
        @peers = {}

        @send_mutex = Mutex.new
        @client_socket = nil
        @server = nil
        @broker_task = nil

        @started = false
      end

      # Whether this process currently holds the broker role. Tracks
      # the elector's view, not the socket state — the broker fiber
      # itself comes up asynchronously inside +on_promote+.
      # @return [Boolean]
      def leader?
        elector = @elector || Sidereal.elector
        elector.leader?
      end

      # Idempotent. Wires broker lifecycle to the elector and spawns a
      # client-reconnect fiber as a transient child of +task+. The
      # client fiber polls until the broker socket exists (created by
      # whichever process the elector promoted) and reads frames.
      def start(task)
        @mutex.synchronize do
          return self if @started
          @started = true
        end

        elector = @elector || Sidereal.elector
        elector.on_promote { setup_broker(task) }
        elector.on_demote { teardown_broker }
        # Idempotent — when wired through Falcon::Service the elector
        # is already started before pubsub.start runs; this call is a
        # no-op in that path. For tests / standalone use, this is
        # what kicks the election off.
        elector.start(task)

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
            @wildcards << [Pattern.compile(pattern), channel]
          else
            (@subscribers[pattern] ||= []) << channel
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
            @wildcards.reject! { |_re, ch| ch.equal?(channel) }
          else
            arr = @subscribers[channel.name]
            next unless arr

            arr.delete(channel)
            @subscribers.delete(channel.name) if arr.empty?
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

      # Local-only fanout. Mirrors {Memory#publish}. Collects matching
      # channels under the lock, then delivers outside it so a subscriber's
      # handler can safely re-enter the pubsub. Skips the array allocation
      # entirely on the hot common path: no exact subscribers + no
      # wildcards (e.g. a publisher process whose subscribers all live
      # remotely).
      def deliver_local(channel_name, event)
        targets = @mutex.synchronize do
          exact = @subscribers[channel_name]
          if @wildcards.empty?
            exact && exact.dup
          else
            list = exact ? exact.dup : []
            @wildcards.each { |re, ch| list << ch if re.match?(channel_name) }
            list.empty? ? nil : list
          end
        end
        targets&.each { |ch| ch << event }
      end

      def encode_frame(channel_name, event)
        attrs = event.to_h
        attrs.transform_values! { |v| v.is_a?(Time) ? v.iso8601(6) : v }
        JSON.generate(channel: channel_name, msg: attrs) << "\n"
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

      # Bring up the broker on this process. Called from the elector's
      # +on_promote+ callback. Replaces any stale socket left by a
      # dead prior leader. Spawns the broker accept loop as a
      # transient child of +task+ so it dies cleanly with the service.
      def setup_broker(task)
        File.unlink(@socket_path) rescue Errno::ENOENT
        @server = UNIXServer.new(@socket_path)
        @broker_task = task.async(transient: true) { run_broker(task) }
        Console.info(self, 'pubsub: elected as broker', pid: Process.pid, socket: @socket_path)
      rescue StandardError => ex
        Console.error(self, 'pubsub broker setup failed', exception: ex)
        teardown_broker
      end

      # Tear down the broker on this process. Called from the
      # elector's +on_demote+ callback. Followers (never-promoted
      # processes) hit this once at startup with no broker to tear
      # down — all branches are nil-safe.
      def teardown_broker
        if (broker = @broker_task)
          @broker_task = nil
          broker.stop
        end

        if (srv = @server)
          @server = nil
          srv.close rescue nil
          Console.info(self, 'pubsub: stepped down as broker', pid: Process.pid)
        end

        # Drain peers via drop_peer so writer fibers blocked on their
        # write_queue.pop see the nil sentinel and exit cleanly. A bare
        # @peers.clear would leak those fibers until parent teardown.
        @peers.keys.each { |peer| drop_peer(peer) }
      end

      # Independent reconnect-with-backoff loop. Runs in every process
      # regardless of election state: the leader connects to its own
      # broker, followers connect to whoever the elector promoted.
      # +Errno::ENOENT+ / +ECONNREFUSED+ during startup or failover
      # are normal — keep retrying.
      def run_client(_task)
        loop do
          run_one_connection
        rescue Errno::ENOENT, Errno::ECONNREFUSED
          # broker not up yet (startup) or just stepped down (failover) — retry
        rescue StandardError => ex
          Console.warn(self, 'pubsub client iteration error', exception: ex)
        ensure
          tear_down_client
          sleep(rand_backoff)
        end
      end

      def run_one_connection
        @client_socket = UNIXSocket.new(@socket_path)
        Console.info(self, 'pubsub: connecting as client', pid: Process.pid, socket: @socket_path)

        @client_socket.each_line do |line|
          begin
            deliver_local(*decode_frame(line))
          rescue StandardError => ex
            Console.error(self, 'pubsub frame decode failed', exception: ex, line: line)
          end
        end
      end

      def tear_down_client
        sock = @client_socket
        @client_socket = nil
        sock&.close rescue nil
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
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError
          # peer disconnected — normal
        rescue StandardError => ex
          Console.warn(self, 'broker peer writer failed', exception: ex)
        ensure
          drop_peer(peer)
        end

        # Reader fiber: each_line → fan out to every other peer.
        task.async(transient: true) do
          peer.each_line { |line| fan_out(line, except: peer) }
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError, EOFError
          # peer disconnected — normal
        rescue StandardError => ex
          Console.warn(self, 'broker peer reader failed', exception: ex)
        ensure
          drop_peer(peer)
        end
      end

      def fan_out(line, except:)
        slow_peers = nil
        @peers_mutex.synchronize do
          @peers.each do |peer, queue|
            next if peer.equal?(except)
            if queue.size >= @write_queue_size
              (slow_peers ||= []) << peer
            else
              queue << line
            end
          end
        end
        slow_peers&.each do |peer|
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
