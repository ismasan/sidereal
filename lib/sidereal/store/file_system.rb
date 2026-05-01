# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require 'time'

module Sidereal
  module Store
    # Filesystem-backed store for cross-process command processing on a single
    # machine. Layout:
    #
    #   <root>/tmp/         producers stage writes here
    #   <root>/ready/       claimable now; main poller scans here
    #   <root>/scheduled/   not_before in the future; scheduler fiber owns
    #   <root>/processing/  claimed by a worker
    #
    # Producers append by atomic-renaming from tmp/ into either ready/ (when
    # +message.created_at <= now+) or scheduled/ (when +created_at+ is in
    # the future). Two transient fibers spawned in {#start}: a poller that
    # claims from ready/ into processing/, and a scheduler that promotes
    # due files from scheduled/ to ready/. A bounded internal queue between
    # the poller and worker fibers provides backpressure.
    #
    # At-least-once delivery: a crash mid-handling causes the message to be
    # re-claimed. Handlers must be idempotent.
    class FileSystem
      DEFAULT_ROOT = 'tmp/sidereal-store'
      DEFAULT_MAX_IN_FLIGHT = 50
      DEFAULT_SCHEDULER_INTERVAL = 1.0

      # Parse a canonical message filename into its component parts.
      # Filename format: +<not_before_ns>-<first_append_ns>-<attempt>-<pid>-<rand>.json+
      # Public so tests and ops tooling can inspect on-disk entries
      # without duplicating the format.
      #
      # @param name [String] basename, with or without the +.json+ suffix
      # @return [Hash] {not_before_ns:, first_append_ns:, attempt:, pid:, rand_hex:}
      def self.parse_filename(name)
        parts = name.delete_suffix('.json').split('-')
        {
          not_before_ns: parts[0].to_i,
          first_append_ns: parts[1].to_i,
          attempt: parts[2].to_i,
          pid: parts[3].to_i,
          rand_hex: parts[4]
        }
      end

      def initialize(
        root: DEFAULT_ROOT,
        poll_interval: 0.1,
        sweep_interval: 60,
        stale_threshold: 300,
        scheduler_interval: DEFAULT_SCHEDULER_INTERVAL,
        max_in_flight: DEFAULT_MAX_IN_FLIGHT
      )
        @root = root
        @tmp_dir = File.join(root, 'tmp')
        @ready_dir = File.join(root, 'ready')
        @scheduled_dir = File.join(root, 'scheduled')
        @processing_dir = File.join(root, 'processing')
        @dead_dir = File.join(root, 'dead')
        @poll_interval = poll_interval
        @sweep_interval = sweep_interval
        @stale_threshold = stale_threshold
        @scheduler_interval = scheduler_interval
        @max_in_flight = max_in_flight
        @last_sweep = Time.at(0)
        @internal_queue = Async::LimitedQueue.new(max_in_flight)
        @poller = nil
        @scheduler = nil
        FileUtils.mkdir_p(@tmp_dir)
        FileUtils.mkdir_p(@ready_dir)
        FileUtils.mkdir_p(@scheduled_dir)
        FileUtils.mkdir_p(@processing_dir)
        FileUtils.mkdir_p(@dead_dir)
      end

      # Append a serialized message so a consumer can later claim it.
      #
      # Routing depends on +message.created_at+:
      #
      # * +created_at <= now+ → ready/ (immediately claimable)
      # * +created_at > now+  → scheduled/ (promoted by the scheduler when due)
      #
      # Uses a write-to-tmp-then-rename pattern: the message is fully
      # written under +tmp/+ first, then atomically renamed into its
      # destination directory. This is required because consumers (the
      # poller fiber) scan ready/ concurrently with producers writing
      # to it, and a naive direct write would expose two failure modes:
      #
      # 1. **Torn reads.** Without the staging step, the consumer can see
      #    the file mid-write — a zero-byte or truncated entry — claim it
      #    by renaming into +processing/+, then fail to deserialize. With
      #    the staging step the file only appears in its destination once
      #    it is complete on disk, because POSIX +rename(2)+ is atomic:
      #    an observer sees either the old name or the new name, never
      #    a half-populated file at the new name.
      #
      # 2. **Crash-mid-write orphans visible to consumers.** If the
      #    producer crashes between +open+ and +close+ while writing
      #    directly to ready/, the partial file lingers there and will
      #    be claimed by a consumer. With staging, a producer crash
      #    leaves the partial file in +tmp/+ where consumers never look,
      #    so it cannot poison the queue.
      #
      # The atomicity guarantee only holds when source and destination
      # are on the same filesystem, which is why all four directories
      # are siblings under a single +root+.
      #
      # @param message [Sidereal::Message]
      # @return [true]
      def append(message)
        now_ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
        created_at_ns = message.created_at.tv_sec * 1_000_000_000 + message.created_at.tv_nsec
        not_before_ns = [created_at_ns, now_ns].max
        first_append_ns = now_ns
        attempt = 1

        name = build_filename(not_before_ns, first_append_ns, attempt)
        tmp_path = File.join(@tmp_dir, name)
        dest_dir = not_before_ns > now_ns ? @scheduled_dir : @ready_dir
        dest_path = File.join(dest_dir, name)
        File.write(tmp_path, serialize(message))
        File.rename(tmp_path, dest_path)
        true
      end

      # Lifecycle hook called by the dispatcher before any {#claim_next}.
      # Spawns two transient fibers as children of +task+:
      #
      # * **Poller** — sweeps stale processing/ files, claims ready/
      #   files into processing/, and pushes paths onto the bounded
      #   internal queue. When handlers fall behind, the queue blocks
      #   and the poller naturally throttles claiming.
      # * **Scheduler** — every +scheduler_interval+ seconds, scans
      #   scheduled/ in due-order and atomically renames any entries
      #   whose +not_before_ns <= now+ into ready/.
      #
      # Idempotent — safe to call repeatedly.
      def start(task)
        return self if @poller

        # transient: true so these fibers do not keep their parent alive —
        # they are stopped when the parent's other (non-transient)
        # children all finish. In production the dispatcher's worker
        # fibers loop forever and keep the parent alive; in tests the
        # consumer fiber is stopped explicitly and the Sync block can
        # then unwind.
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

        @scheduler = task.async(transient: true) do
          loop do
            promote_due
            sleep @scheduler_interval
          end
        end

        self
      end

      # Pop one path from the internal queue, deserialize, yield with
      # per-claim {Sidereal::Store::Meta}, and act on the block's return.
      # The block must return a {Sidereal::Store::Result} value:
      #
      #   Result::Ack             — unlink processing/<f>
      #   Result::Retry.new(at:)  — rename processing/<f> → scheduled/<f'>
      #                             with bumped attempt and new not_before_ns;
      #                             body untouched
      #   Result::Fail.new(error:) — write sidecar dead/<f>.error.json with
      #                              {class, message, backtrace}, then rename
      #                              processing/<f> → dead/<f>; body untouched
      #
      # Any other return value (or +nil+) is treated as Ack with a WARN log.
      #
      # If the block itself raises (which the dispatcher takes pains to
      # avoid), the file stays in processing/ and the sweeper recovers it
      # on its next pass. May be called concurrently by N fibers; each
      # path goes to exactly one caller.
      #
      # @yieldparam message [Sidereal::Message]
      # @yieldparam meta [Sidereal::Store::Meta]
      # @yieldreturn [Sidereal::Store::Result]
      def claim_next
        loop do
          claimed_path = @internal_queue.pop
          message = deserialize(File.read(claimed_path))
          meta = build_meta(claimed_path)
          result = yield message, meta
          handle_result(result, claimed_path, meta)
        end
      end

      private

      # Build per-claim Meta by parsing the original filename out of the
      # processing-side name (which is +<original>__<pid>__<claim_ns>+)
      # and extracting +attempt+ and +first_append_ns+ from it.
      def build_meta(processing_path)
        processing_name = File.basename(processing_path)
        original, _pid, _claim_ns = parse_processing_name(processing_name)
        parts = self.class.parse_filename(original)
        ns = parts[:first_append_ns]
        Sidereal::Store::Meta.new(
          attempt: parts[:attempt],
          first_appended_at: Time.at(ns / 1_000_000_000, ns % 1_000_000_000, :nsec)
        )
      end

      def handle_result(result, claimed_path, meta)
        case result
        in Sidereal::Store::Result::Ack
          File.unlink(claimed_path)
        in Sidereal::Store::Result::Retry(at:)
          reschedule(claimed_path, at, meta)
        in Sidereal::Store::Result::Fail(error:)
          dead_letter(claimed_path, error)
        else
          Console.warn(self, 'malformed claim_next return value; treating as ack',
                       path: claimed_path, result: result.inspect)
          File.unlink(claimed_path)
        end
      end

      # Move a processing/ entry back to scheduled/ with a new
      # not_before_ns and bumped attempt. The first_append_ns is
      # preserved so age-based policies stay correct across retries.
      # Body is not rewritten.
      def reschedule(claimed_path, at_time, meta)
        original_name = parse_processing_name(File.basename(claimed_path))[0]
        parts = self.class.parse_filename(original_name)
        new_not_before_ns = at_time.tv_sec * 1_000_000_000 + at_time.tv_nsec
        new_name = build_filename(
          new_not_before_ns,
          parts[:first_append_ns],
          meta.attempt + 1
        )
        File.rename(claimed_path, File.join(@scheduled_dir, new_name))
      end

      # Permanently move a processing/ entry into dead/ and write a
      # sidecar with the exception details. Sidecar is staged through
      # tmp/ so an observer never sees a partial write. Body is not
      # rewritten — the sidecar carries the failure context.
      #
      # Crash safety: if we die between the sidecar rename and the
      # message rename, the sidecar lives in dead/ but the message is
      # still in processing/ → sweeper recovers it → handler runs again
      # → likely fails again → sidecar is overwritten.
      def dead_letter(claimed_path, exception)
        original_name = parse_processing_name(File.basename(claimed_path))[0]
        sidecar_name = "#{original_name}.error.json"
        sidecar_payload = JSON.dump(
          class: exception.class.name,
          message: exception.message,
          backtrace: exception.backtrace || []
        )
        tmp_sidecar = File.join(@tmp_dir, sidecar_name)
        File.write(tmp_sidecar, sidecar_payload)
        File.rename(tmp_sidecar, File.join(@dead_dir, sidecar_name))
        File.rename(claimed_path, File.join(@dead_dir, original_name))
      end

      def try_claim
        Dir.children(@ready_dir).sort.each do |entry|
          src = File.join(@ready_dir, entry)
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

      # Scan scheduled/ in filename-sorted order and promote any entries
      # whose +not_before_ns <= now+ into ready/. Filename sort puts
      # earliest-due first; we stop at the first not-yet-due entry since
      # everything after it has an even later +not_before_ns+.
      def promote_due
        now_ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
        Dir.children(@scheduled_dir).sort.each do |entry|
          not_before_ns = parse_not_before_ns(entry)
          break if not_before_ns && not_before_ns > now_ns

          src = File.join(@scheduled_dir, entry)
          dst = File.join(@ready_dir, entry)
          begin
            File.rename(src, dst)
          rescue Errno::ENOENT
            next
          end
        end
      end

      def parse_not_before_ns(entry)
        prefix, _ = entry.split('-', 2)
        return nil unless prefix && prefix.match?(/\A\d+\z/)

        prefix.to_i
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
            dst = File.join(@ready_dir, original)
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

      def build_filename(not_before_ns, first_append_ns, attempt)
        "#{not_before_ns}-#{first_append_ns}-#{attempt}-#{Process.pid}-#{SecureRandom.hex(4)}.json"
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
