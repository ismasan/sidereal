# frozen_string_literal: true

require 'fileutils'
require 'console'

module Sidereal
  module Elector
    # Filesystem-backed leader election via +flock+ on a shared lock
    # file. Single-host only — flock is unreliable across NFS.
    #
    # The first process to acquire +LOCK_EX | LOCK_NB+ on +lock_path+
    # becomes leader and holds the lock until the process exits or the
    # election fiber is cancelled (whichever comes first). Followers
    # poll +retry_interval+ seconds to detect a vacancy. flock is
    # auto-released by the kernel on process death — no stale-lock
    # cleanup required.
    class FileSystem
      include Callbacks

      DEFAULT_RETRY_INTERVAL = 1.0

      attr_reader :lock_path

      def initialize(lock_path:, retry_interval: DEFAULT_RETRY_INTERVAL)
        @lock_path = File.expand_path(lock_path)
        @retry_interval = retry_interval
        @leader = false
        @lock_io = nil
        FileUtils.mkdir_p(File.dirname(@lock_path))
      end

      def leader? = @leader

      # Spawn the election fiber as a transient child of +task+. The
      # fiber polls for the lock until acquired, then sleeps holding
      # it. Cancellation (parent task ending or {#stop}) releases the
      # lock and fires +on_demote+ callbacks via the +ensure+ block.
      # Idempotent — safe to call multiple times (e.g. once from
      # {Falcon::Environment::Service} and once from
      # {PubSub::Unix#start}).
      def start(task)
        return self if @election_task

        @election_task = task.async(transient: true) do
          run_election
        ensure
          release_lock
          demote!
        end
        self
      end

      # Voluntarily step down: cancel the election fiber, which
      # releases the flock and fires +on_demote+ via the +ensure+
      # block in {#start}. Idempotent.
      def stop
        t = @election_task
        @election_task = nil
        t&.stop
        self
      end

      private

      def run_election
        loop do
          if try_acquire_lock
            promote!
            # Hold the lock indefinitely. flock survives until the file
            # is closed (cancellation path) or the process dies. A long
            # sleep keeps the fiber alive without busy-waiting; the
            # transient cancellation interrupts it cleanly.
            loop { sleep 3600 }
          else
            sleep @retry_interval
          end
        end
      end

      def try_acquire_lock
        io = File.open(@lock_path, File::RDWR | File::CREAT, 0o644)
        if io.flock(File::LOCK_EX | File::LOCK_NB)
          @lock_io = io
          Console.info(self, 'elected as leader', pid: Process.pid, lock: @lock_path)
          true
        else
          io.close
          false
        end
      end

      def release_lock
        return unless @lock_io

        io = @lock_io
        @lock_io = nil
        io.close rescue nil
        Console.info(self, 'stepped down', pid: Process.pid, lock: @lock_path)
      end
    end
  end
end
