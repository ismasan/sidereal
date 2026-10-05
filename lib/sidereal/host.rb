# frozen_string_literal: true

module Sidereal
  # Boot orchestrator for a Sidereal process: starts {Sidereal.config} in a
  # task, and tears it down. Hosts (the Falcon service, tests, CLIs) share it
  # rather than each driving the lifecycle.
  #
  # The order is the components' dependency order (see {Config}): every
  # component is built first, in every process, leader or follower, so a
  # process that only appends is as ready as the one that consumes. Then
  # start hooks run: the registries lock, the elector and pubsub start, the
  # runner starts the dispatcher (now, or when the elector promotes this
  # process) and the scheduler starts. {#stop} stops the dispatcher, then
  # tears down in reverse order.
  #
  # @example Driven by the Falcon service
  #   host = Sidereal.new_host
  #   Async do |task|
  #     host.start(task)
  #     task.children.each(&:wait)
  #   end
  #   # ...on shutdown:
  #   host.stop
  class Host
    # @param config [Sourced::Component] the root to boot, see {Sidereal.config}
    def initialize(config:)
      @config = config
    end

    # Build and start every component. A component that fails to build or
    # start fails the boot: the ones already started are torn down, and the
    # exception reaches the caller (the Falcon service routes it to its
    # boot-failure path).
    #
    # @param task [Async::Task] long-lived parent task; components spawn their
    #   background fibers as children of it
    # @return [self]
    def start(task)
      @config.start!(task)
      self
    end

    # Stop the dispatcher, then tear down every component, in reverse
    # dependency order. The dispatcher goes first explicitly: its handlers can
    # use any component (ex. an app's +db+, injected with +dep+), which the
    # dependency order alone doesn't place after it. A no-op unless started.
    # Components' fibers are children of the task passed to {#start} and end
    # with it.
    #
    # @return [void]
    def stop
      return unless @config.boot_status == :started

      @config['sidereal.runner'].stop
      @config.teardown!
    end
  end
end
