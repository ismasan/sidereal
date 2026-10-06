# frozen_string_literal: true

module Sidereal
  # Decides where and when the dispatcher runs. The +runner+ component starts
  # it on start and stops it on teardown (see {Config}).
  #
  # Its targets are deferred components (see +Sourced::Component#defer+), by key
  # relative to the root: Sidereal's dispatcher by default, or whatever an
  # integration points +sidereal.runner.targets+ at, ex. Sourced's dispatcher.
  # The runner starts and stops them by key, which follows the dependency
  # graph: starting one starts any of its dependencies that aren't running,
  # and stopping one stops whatever depends on it first.
  #
  # - +:all+: every process starts them, now.
  # - +:leader+: only the process the elector promotes starts them. They're
  #   stopped if that process is demoted, and started again if it's promoted
  #   again, so they start and stop possibly more than once.
  #
  # Web requests keep appending to the store from every process; only the
  # consuming side is pinned. Useful when the backend serializes writers
  # (Sourced on SQLite), so reads scale across processes while handler and
  # projection writes come from one.
  #
  # With an elector that is leader from the start ({Elector::AlwaysLeader})
  # the two coincide: +on_promote+ fires at once.
  class DispatcherRunner
    # @param config [Sourced::Component] the root its targets' keys are relative to
    # @param targets [Array<String>] keys of deferred components
    # @param elector [#on_promote, #on_demote]
    # @param process [Symbol] +:all+ or +:leader+
    def initialize(config:, targets:, elector:, process: :all)
      @config = config
      @targets = targets
      @elector = elector
      @process = Config::DispatcherProcess.parse(process)
      @running = false
      @stopped = false
    end

    # Whether its targets are running in this process
    def running? = @running

    # @param task [Async::Task] parent of the targets' fibers
    # @return [self]
    # @raise [ArgumentError] if a target isn't deferred, so the root starts it
    #   in every process, whatever this runner decides
    def start(task)
      undeferred = @targets.reject { |key| @config.node(key).deferred? }
      if undeferred.any?
        raise ArgumentError, "#{undeferred.join(', ')} must be deferred to be run by the runner: " \
                             'otherwise the root starts it in every process'
      end

      case @process
      when :all
        start_targets(task)
      when :leader
        # on_demote fires now on a follower, with nothing to stop
        @elector.on_promote { start_targets(task) }
        @elector.on_demote { stop_targets }
      end
      self
    end

    # Stop the targets, for good: a later promotion doesn't start them again.
    # @return [void]
    def stop
      @stopped = true
      stop_targets
    end

    private

    def start_targets(task)
      return if @running || @stopped

      @targets.each { |key| @config.start_component!(key, task) }
      @running = true
    end

    def stop_targets
      return unless @running

      @running = false
      @targets.reverse_each { |key| @config.stop_component!(key) }
    end
  end
end
