# frozen_string_literal: true

require 'sidereal/dispatcher'

module Sidereal
  module Falcon
    # Environment mixin for configuring a combined Falcon web server + workers service.
    #
    # Include this module in a Falcon service definition to get Sidereal worker defaults
    # alongside the standard Falcon server environment. All settings are read from...
    #
    # The Service automatically calls {Sidereal.setup!} at the start of +run+ to
    # re-establish database connections after Falcon forks (SQLite connections
    # are not fork-safe).
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
          Sidereal.setup!

          server = evaluator.make_server(@bound_endpoint)

          @dispatcher = nil

          Async do |task|
            server.run
            @dispatcher = Sidereal.dispatcher.spawn_into(task)

            task.children.each(&:wait)
          end

          server
        end

        def stop(...)
          @dispatcher&.stop
          super
        end
      end

      def service_class = Service
    end
  end
end
