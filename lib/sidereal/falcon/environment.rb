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
      class Service < ::Falcon::Service::Server
        def run(instance, evaluator)
          # make_server loads the rackup app (config.ru → boot.rb), which runs
          # Sidereal.configure — so the config is populated by the time we check.
          server = evaluator.make_server(@bound_endpoint)

          # Fail fast: refuse to boot in-process-only subsystems across forked
          # workers (their in-memory state isn't shared, so SSE fan-out would
          # silently fail). Logs a loud error and exits before serving anything.
          Sidereal.check_topology!(worker_count(evaluator))

          @sidereal_host = Sidereal.new_host

          Async do |task|
            server.run
            @sidereal_host.start(task)

            task.children.each(&:wait)
          end

          server
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
