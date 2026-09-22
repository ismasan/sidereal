# frozen_string_literal: true

module Sidereal
  # Boot orchestrator for a Sidereal process. Bundles the runtime
  # collaborators and drives them through a single +start+/+stop+
  # lifecycle, so hosts (the Falcon service, tests, CLIs) don't each
  # re-implement the boot sequence.
  #
  # {#start} is the one place that decides ordering: it runs the boot
  # hooks (per-process preparation registered via
  # {Sidereal::Configuration#on_boot}), locks the channels and exceptions
  # registries (boot-time registration is over) and then brings the
  # subsystems up in dependency order — elector before pubsub (the Unix
  # pubsub consults the elector for leadership), and both before the
  # dispatcher's workers begin consuming. {#stop} tears down the running
  # dispatcher captured from +dispatcher.start+.
  #
  # +dispatcher_process+ decides where that dispatcher runs. With +:all+
  # every process starts one at boot. With +:leader+ the factory is
  # invoked from the elector's +on_promote+ and the instance stopped from
  # +on_demote+, so exactly one process per elector scope consumes, and
  # a successor starts its own after a failover. Under an elector that is
  # leader from construction the two modes coincide. Note that a
  # dispatcher failing to start on a *later* promotion is logged by the
  # elector's callback guard rather than failing the boot — promotion
  # happens after boot.
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
    # @param dispatcher_process [Symbol] +:all+ or +:leader+; see
    #   {Sidereal::Configuration#dispatcher_process}
    # @param boot_hooks [Array<#call>] run in order by {#start}, in every
    #   process, before anything else; see {Sidereal::Configuration#on_boot}
    def initialize(channels:, exceptions:, elector:, pubsub:, dispatcher:, scheduler:, dispatcher_process: :all,
                   boot_hooks: [])
      @channels = channels
      @exceptions = exceptions
      @elector = elector
      @pubsub = pubsub
      @dispatcher = dispatcher
      @scheduler = scheduler
      @dispatcher_process = DispatcherProcess.parse(dispatcher_process)
      @boot_hooks = boot_hooks
      @dispatcher_instance = nil
    end

    # Run the boot hooks, lock the registries, then start every
    # subsystem in dependency order. The captured return of
    # +dispatcher.start+ is retained for {#stop} — the dispatcher field is
    # a factory, so its +start+ yields a distinct running instance (unlike
    # elector/pubsub/scheduler, which return themselves).
    #
    # A boot hook that raises fails the boot: nothing after it starts, and
    # the exception reaches the caller (the Falcon service routes it to its
    # boot-failure path).
    #
    # @param task [Async::Task] long-lived parent task; each subsystem's
    #   background fibers are spawned as children of it
    # @return [self]
    def start(task)
      # Per-process preparation first, while the registries are still
      # open: a hook may register subscribers, and everything below
      # (leader or not) may depend on what it sets up.
      @boot_hooks.each(&:call)

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
      case @dispatcher_process
      when :all
        start_dispatcher(task)
      when :leader
        # on_promote fires now if already leader, so an always-leader
        # elector starts the dispatcher here, before the scheduler, just
        # like :all. on_demote fires now on a follower, with nothing to stop.
        @elector.on_promote { start_dispatcher(task) }
        @elector.on_demote { stop_dispatcher }
      end
      @scheduler.start(task)
      self
    end

    # Stop the running dispatcher captured during {#start}. A no-op when
    # {#start} was never called or nothing is running. The other
    # subsystems' fibers are children of the task passed to {#start} and
    # are torn down when that task ends, so they need no explicit stop here.
    #
    # @return [void]
    def stop
      stop_dispatcher
    end

    private

    def start_dispatcher(task)
      return if @dispatcher_instance

      @dispatcher_instance = @dispatcher.start(task)
    end

    def stop_dispatcher
      instance = @dispatcher_instance
      @dispatcher_instance = nil
      instance&.stop
    end
  end
end
