# frozen_string_literal: true

module Sidereal
  # Boot orchestrator for a Sidereal process. Bundles the runtime
  # collaborators and drives them through a single +start+/+stop+
  # lifecycle, so hosts (the Falcon service, tests, CLIs) don't each
  # re-implement the boot sequence.
  #
  # {#start} is the one place that decides ordering: it locks the
  # channels and exceptions registries (boot-time registration is over)
  # and then brings the subsystems up in dependency order — elector
  # before pubsub (the Unix pubsub consults the elector for leadership),
  # and both before the dispatcher's workers begin consuming. {#stop}
  # tears down the running dispatcher captured from +dispatcher.start+.
  #
  # Collaborators are injected (see {Sidereal.new_host} for the wiring
  # from global config), which keeps the class unit-testable with fakes.
  #
  # @example Driven by the Falcon service
  #   host = Sidereal.new_host
  #   Async do |task|
  #     host.start(task)        # lock registries, start subsystems
  #     task.children.each(&:wait)
  #   end
  #   # ...on shutdown:
  #   host.stop
  class Host
    # @param channels [Sidereal::Channels] channel-name registry; frozen by {#start}
    # @param exceptions [Sidereal::Exceptions] exception-subscriber registry; frozen by {#start}
    # @param elector [#start] leader elector
    # @param pubsub [#start] pub/sub backend
    # @param dispatcher [#start] dispatcher *factory* (e.g. the
    #   {Sidereal::Dispatcher} class, or +Sourced::Dispatcher+) whose
    #   +#start+ returns the running instance that {#stop} later stops
    # @param scheduler [#start] scheduled-command ticker
    def initialize(channels:, exceptions:, elector:, pubsub:, dispatcher:, scheduler:)
      @channels = channels
      @exceptions = exceptions
      @elector = elector
      @pubsub = pubsub
      @dispatcher = dispatcher
      @scheduler = scheduler
      @dispatcher_instance = nil
    end

    # Lock the registries, then start every subsystem in dependency
    # order. The captured return of +dispatcher.start+ is retained for
    # {#stop} — the dispatcher field is a factory, so its +start+ yields
    # a distinct running instance (unlike elector/pubsub/scheduler, which
    # return themselves).
    #
    # @param task [Async::Task] long-lived parent task; each subsystem's
    #   background fibers are spawned as children of it
    # @return [self]
    def start(task)
      # Boot is over: classes have loaded, channel routes and
      # exception subscribers are registered. Lock both registries
      # so any further +channel_name(...)+ / +on_retry+ /
      # +on_failure+ call raises loudly instead of silently racing
      # the worker fibers about to start consuming.
      @channels.lock!
      @exceptions.lock!

      # Start the configured pubsub here (not inside the dispatcher)
      # so it works regardless of which dispatcher implementation is
      # plugged in — e.g. Sourced's Dispatcher in examples/sourced_donations
      # also benefits from the long-lived Falcon task as the parent for
      # pubsub's background fibers.
      @elector.start(task)
      @pubsub.start(task)
      @dispatcher_instance = @dispatcher.start(task)
      @scheduler.start(task)
      self
    end

    # Stop the running dispatcher captured during {#start}. A no-op when
    # {#start} was never called. The other subsystems' fibers are
    # children of the task passed to {#start} and are torn down when that
    # task ends, so they need no explicit stop here.
    #
    # @return [void]
    def stop
      @dispatcher_instance&.stop
    end
  end
end
