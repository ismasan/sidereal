# frozen_string_literal: true

require 'etc'
require 'falcon/environment/server'
require 'falcon/environment/rackup'
require 'falcon/service/server'
require 'sidereal/dispatcher'

module Sidereal
  module Falcon
    # Environment mixin for configuring a combined Falcon web server + workers service.
    #
    # Include this module in a Falcon service definition to get Sidereal worker defaults
    # alongside the standard Falcon server environment. All settings are read from...
    #
    # Each worker loads the rackup app (config.ru → boot.rb) in its own
    # process via +make_server+, so fork-unsafe collaborators (e.g. SQLite
    # connections) are established fresh per worker — no post-fork
    # reconnection step is needed.
    #
    # @example falcon.rb
    #   #!/usr/bin/env falcon-host
    #   require 'sidereal/falcon/environment'
    #
    #   service "my-app" do
    #     include Sidereal::Falcon::Environment
    #     include Falcon::Environment::Rackup
    #
    #     url "http://[::]:9292"
    #   end
    module Environment
      include ::Falcon::Environment::Server

      # A Falcon service that runs both the web server and background workers
      # as sibling fibers within the same Async reactor.
      #
      # Boot runs inside a forked worker, under two behaviours of the
      # surrounding machinery that together turn a boot bug into a silent crash
      # loop, so {#run} ends every boot failure at {#terminate_host!}:
      #
      # - async-service invokes {#run} from a fire-and-forget +Async+ task, so an
      #   exception escaping it is reported only as Async's "Task may have ended
      #   with unhandled exception" warning — which {Sidereal::Logging} silences
      #   along with the SSE disconnect warnings it targets.
      # - The container spawns workers with +restart: true+, so a worker that
      #   dies during boot is respawned forever. The failure repeats every few
      #   milliseconds and the host never exits.
      class Service < ::Falcon::Service::Server
        # Runs in the controller process, before the container forks any worker,
        # so each worker inherits the controller's pid and can tell whether it is
        # a forked child (and therefore has a controller to interrupt).
        def start
          @controller_pid = ::Process.pid
          super
        end

        # Falcon (0.56+) passes the worker's bound {Falcon::Listener} as the
        # third argument; the server binds to its endpoint.
        def run(instance, evaluator, listener = @listener)
          # make_server loads the rackup app (config.ru → boot.rb), which runs
          # Sidereal.configure — so the config is populated by the time we check.
          server = evaluator.make_server(listener.endpoint)

          # Fail fast: refuse to boot in-process-only subsystems across forked
          # workers (their in-memory state isn't shared, so SSE fan-out would
          # silently fail). Logs a loud error and exits before serving anything.
          Sidereal.check_topology!(worker_count(evaluator))

          @sidereal_host = Sidereal.new_host

          Async do |task|
            # Guarded separately from the body above: this block is a
            # fire-and-forget task, so a subsystem that fails to start (a store
            # directory, an elector lock, a pubsub socket) raises here, where
            # #run has already returned and cannot rescue it. Only the two boot
            # calls are covered — waiting on the children below is the running
            # state, not boot.
            begin
              server.run
              @sidereal_host.start(task)
            rescue ::SignalException
              raise
            rescue ::Exception => e # rubocop:disable Lint/RescueException
              boot_failed!(e)
            end

            task.children.each(&:wait)
          end

          server
        rescue ::SignalException
          # The host is already shutting down and said so; nothing to report.
          raise
        rescue ::SystemExit => e
          # A boot check (e.g. Sidereal.check_topology!) already logged what is
          # wrong and asked for this process to exit. Widen that to the host.
          terminate_host!(e.status)
        rescue ::Exception => e # rubocop:disable Lint/RescueException
          # Exception, not StandardError: a boot that fails on a NoMethodError
          # deserves the same report as one that fails on a NotImplementedError
          # or a script-level Exception, and none of them may reach the restart
          # loop unreported.
          boot_failed!(e)
        end

        # Report a boot failure and end the host.
        #
        # @param error [Exception]
        # @return [void] does not return
        def boot_failed!(error)
          Console.error(self, 'Sidereal failed to boot. Terminating host.', exception: error)
          terminate_host!(1)
        end

        # End the whole host, not this worker alone: a boot failure is a bug in
        # the app or its configuration, identical on every worker and on every
        # respawn, so the only useful outcome is a stopped host with one legible
        # error. Interrupting the controller is what stops the other workers —
        # it puts the container into its stopping state, which is the flag that
        # suppresses respawning.
        #
        # Public so tests can drive {#run}'s failure paths without exiting the
        # test process.
        #
        # @param status [Integer] exit status for this worker
        # @return [void] does not return
        def terminate_host!(status)
          if @controller_pid && @controller_pid != ::Process.pid
            begin
              ::Process.kill(:INT, @controller_pid)
            rescue SystemCallError => e
              # An already-dead controller is the outcome we wanted anyway.
              Console.warn(self, 'Could not interrupt the host controller.', exception: e)
            end
          end

          # exit!, not exit: this process is a fork of the controller, so a
          # normal exit would run at_exit handlers the controller registered.
          exit!(status)
        end

        # Number of forked worker processes Falcon runs for this service.
        # Falcon's managed environment returns +nil+ from +count+ to mean "one
        # per processor" (+Etc.nprocessors+); resolve that so the topology check
        # sees the real fork count. Defensive: any failure falls back to 1.
        #
        # @param evaluator [Object] the Falcon environment evaluator
        # @return [Integer]
        private def worker_count(evaluator)
          count = evaluator.respond_to?(:count) ? evaluator.count : 1
          (count || Etc.nprocessors).to_i
        rescue StandardError
          1
        end

        def stop(...)
          @sidereal_host&.stop
          super
        end
      end

      def service_class = Service
    end
  end
end
