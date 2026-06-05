# frozen_string_literal: true

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
          server = evaluator.make_server(@bound_endpoint)

          @sidereal_host = Sidereal.new_host

          Async do |task|
            server.run
            @sidereal_host.start(task)

            task.children.each(&:wait)
          end

          server
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
