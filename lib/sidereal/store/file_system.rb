# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require 'time'

module Sidereal
  module Store
    # Filesystem-backed store for cross-process command processing on a single
    # machine. Producers append by atomic-renaming into pending/. A single
    # poller fiber (spawned in {#start}) sweeps, claims pending files into
    # processing/, and pushes paths onto a bounded internal queue. Worker
    # fibers calling {#claim_next} pop from that queue, so concurrency in
    # handlers does not amplify directory polling.
    #
    # At-least-once delivery: a crash mid-handling causes the message to be
    # re-claimed. Handlers must be idempotent.
    class FileSystem
      DEFAULT_ROOT = 'tmp/sidereal-store'
      DEFAULT_MAX_IN_FLIGHT = 50

      def initialize(
        root: DEFAULT_ROOT,
        poll_interval: 0.1,
        sweep_interval: 60,
        stale_threshold: 300,
        max_in_flight: DEFAULT_MAX_IN_FLIGHT
      )
        @root = root
        @tmp_dir = File.join(root, 'tmp')
        @pending_dir = File.join(root, 'pending')
        @processing_dir = File.join(root, 'processing')
        @poll_interval = poll_interval
        @sweep_interval = sweep_interval
        @stale_threshold = stale_threshold
        @max_in_flight = max_in_flight
        @last_sweep = Time.at(0)
        @internal_queue = Async::LimitedQueue.new(max_in_flight)
        @poller = nil
        FileUtils.mkdir_p(@tmp_dir)
        FileUtils.mkdir_p(@pending_dir)
        FileUtils.mkdir_p(@processing_dir)
      end

      # Append a serialized message so a consumer can later claim it.
      #
      # Uses a write-to-tmp-then-rename pattern: the message is fully
      # written under +tmp/+ first, then atomically renamed into +pending/+.
      # This is required because consumers (the poller fiber) scan
      # +pending/+ concurrently with producers writing to it, and a naive
      # +File.write(pending_path, ...)+ would expose two failure modes:
      #
      # 1. **Torn reads.** Without the staging step, the consumer can see
      #    the file mid-write — a zero-byte or truncated entry — claim it
      #    by renaming into +processing/+, then fail to deserialize. With
      #    the staging step the file only appears in +pending/+ once it
      #    is complete on disk, because POSIX +rename(2)+ is atomic: an
      #    observer sees either the old name or the new name, never a
      #    half-populated file at the new name.
      #
      # 2. **Crash-mid-write orphans visible to consumers.** If the
      #    producer crashes between +open+ and +close+ while writing
      #    directly to +pending/+, the partial file lingers there and
      #    will be claimed by a consumer. With staging, a producer crash
      #    leaves the partial file in +tmp/+ where consumers never look,
      #    so it cannot poison the queue.
      #
      # The atomicity guarantee only holds when source and destination
      # are on the same filesystem, which is why +tmp/+, +pending/+, and
      # +processing/+ are sibling directories under a single +root+.
      #
      # @param message [Sidereal::Message]
      # @return [true]
      def append(message)
        name = next_filename
        tmp_path = File.join(@tmp_dir, name)
        pending_path = File.join(@pending_dir, name)
        File.write(tmp_path, serialize(message))
        File.rename(tmp_path, pending_path)
        true
      end

      # Lifecycle hook called by the dispatcher before any {#claim_next}.
      # Spawns a single poller fiber as a child of +task+ that sweeps,
      # claims pending files, and pushes paths onto the bounded internal
      # queue. When handlers fall behind, the queue blocks and the poller
      # naturally throttles claiming. Idempotent — safe to call repeatedly.
      def start(task)
        return self if @poller

        # transient: true so the poller does not keep its parent alive — it
        # is stopped when the parent's other (non-transient) children all
        # finish. In production the dispatcher's worker fibers loop forever
        # and keep the parent alive; in tests the consumer fiber is stopped
        # explicitly and the Sync block can then unwind.
        @poller = task.async(transient: true) do
          loop do
            sweep_if_due
            claimed_path = try_claim
            if claimed_path
              @internal_queue << claimed_path
            else
              sleep @poll_interval
            end
          end
        end

        self
      end

      # Pop one path from the internal queue, deserialize, yield, then
      # unlink the processing file on successful return. If the block
      # raises, the file stays in processing/ and the sweeper recovers
      # it. May be called concurrently by N fibers; each path goes to
      # exactly one caller.
      def claim_next
        loop do
          claimed_path = @internal_queue.pop
          yield deserialize(File.read(claimed_path))
          File.unlink(claimed_path)
        end
      end

      private

      def try_claim
        Dir.children(@pending_dir).sort.each do |entry|
          src = File.join(@pending_dir, entry)
          dst_name = "#{entry}__#{Process.pid}__#{Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)}"
          dst = File.join(@processing_dir, dst_name)
          begin
            File.rename(src, dst)
            return dst
          rescue Errno::ENOENT
            next
          end
        end
        nil
      end

      def sweep_if_due
        return if Time.now - @last_sweep < @sweep_interval
        @last_sweep = Time.now
        sweep!
      end

      def sweep!
        Dir.children(@processing_dir).each do |entry|
          original, claim_pid, claim_ns = parse_processing_name(entry)
          next unless original

          if process_dead?(claim_pid) || stale?(claim_ns)
            src = File.join(@processing_dir, entry)
            dst = File.join(@pending_dir, original)
            begin
              File.rename(src, dst)
            rescue Errno::ENOENT
              # another sweeper got it
            end
          end
        end
      end

      def parse_processing_name(entry)
        # original_filename__pid__claim_ns
        parts = entry.rpartition('__')
        return nil if parts[1].empty?

        rest = parts[0]
        claim_ns = parts[2].to_i
        parts2 = rest.rpartition('__')
        return nil if parts2[1].empty?

        original = parts2[0]
        pid = parts2[2].to_i
        [original, pid, claim_ns]
      end

      def process_dead?(pid)
        return true if pid <= 0

        Process.kill(0, pid)
        false
      rescue Errno::ESRCH
        true
      rescue Errno::EPERM
        false # alive but owned by another user
      end

      def stale?(claim_ns)
        return false if claim_ns.zero?

        now_ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
        (now_ns - claim_ns) > (@stale_threshold * 1_000_000_000)
      end

      def next_filename
        ts = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
        "#{ts}-#{Process.pid}-#{SecureRandom.hex(4)}.json"
      end

      def serialize(message)
        attrs = message.to_h
        attrs.each do |k, v|
          attrs[k] = v.iso8601(6) if v.is_a?(Time)
        end
        JSON.dump(attrs)
      end

      def deserialize(json_str)
        attrs = JSON.parse(json_str, symbolize_names: true)
        Sidereal::Message.from(attrs)
      end
    end
  end
end
