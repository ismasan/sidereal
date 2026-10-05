# frozen_string_literal: true

require 'sourced/component'

module Sidereal
  # Sidereal's components: a tree (see sourced-component) with defaults,
  # dependencies and a lifecycle. {Sidereal.component} is one, mounted at
  # +sidereal+ in the app's root, {Sidereal.config}:
  #
  #   Sidereal.config.config!('sidereal.workers.count') { 4 }
  #   Sidereal.config.start!(task)
  #
  # The tree:
  #
  #   elector             AlwaysLeader. Started first: the pubsub may consult it
  #   pubsub              PubSub::Memory. Depends on elector, so it starts after it
  #   store               Store::Memory: where commands are appended
  #   channels            Sidereal.channels. Locked on start
  #   exceptions          Sidereal.exceptions. Locked on start
  #   workers.count       worker fibers the default dispatcher runs
  #   dispatcher          consumes the store: Sidereal::Dispatcher. Deferred: the
  #                       runner starts and stops it by key, possibly several times
  #   runner              starts its targets, now or on promotion (see
  #                       DispatcherRunner), and stops them on demotion and teardown
  #   runner.targets      keys of the deferred components the runner starts, relative
  #                       to the root: the dispatcher. An integration that brings its
  #                       own dispatcher points it there instead
  #   runner.process      :all (every process runs the targets) or :leader (only the
  #                       one the elector promotes)
  #   scheduler           Sidereal.scheduler. Ticks on the leader, after the runner starts
  #
  # Components that run in the background (elector, pubsub, scheduler) start
  # themselves in their component's start hook, which a re-implementation
  # replaces: one that re-implements them brings its own start hook.
  #
  # The registries (channels, exceptions) are filled as classes load, before
  # anything is built, so they are process globals that their components
  # return. They lock on start: every component builds before any starts, so
  # a build can still register a resolver or a subscriber, and the dispatcher
  # depends on both, so they are locked before it consumes.
  module Config
    T = Sourced::Component::T

    PubsubInterface = T::Interface[:start, :subscribe, :publish]
    ElectorInterface = T::Interface[:start, :on_promote, :on_demote, :leader?]
    # Sidereal apps only append to stores. It's up to dispatchers how to
    # claim from them: Sourced's store has its own claim mechanism.
    StoreWriterInterface = T::Interface[:append]
    ChannelsInterface = T::Interface[:for, :lock!]
    ExceptionsInterface = T::Interface[:report_retry, :report_failure, :report_fatal, :lock!]
    # Started and stopped by the runner, possibly more than once per process
    DispatcherInterface = T::Interface[:start, :stop]
    SchedulerInterface = T::Interface[:start]
    # Which process runs the dispatcher: every process, or only the one the
    # elector promotes. See DispatcherRunner.
    DispatcherProcess = T::Value[:all] | T::Value[:leader]

    # A fresh, open tree, with defaults for every component.
    # @return [Sourced::Component]
    def self.build
      Sourced::Component.new.tap do |c|
        c.declare('elector', ElectorInterface)
        c.component!('elector') do
          build { Elector::AlwaysLeader.new }
          start { |elector, task| elector.start(task) }
        end

        c.declare('pubsub', PubsubInterface)
        c.component!('pubsub', ['elector']) do
          build { |_elector| PubSub::Memory.instance }
          start { |pubsub, task| pubsub.start(task) }
        end

        c.declare('store', StoreWriterInterface) { Store::Memory.instance }

        c.declare('channels', ChannelsInterface)
        c.component!('channels') do
          build { Sidereal.channels }
          start { |channels, _| channels.lock! }
        end

        c.declare('exceptions', ExceptionsInterface)
        c.component!('exceptions') do
          build { Sidereal.exceptions }
          start { |exceptions, _| exceptions.lock! }
        end

        c.declare('workers.count', T::Integer[0..]) { 25 }

        # Deferred, so the root's start doesn't start it in every process: the runner does
        c.declare('dispatcher', DispatcherInterface)
        c.component!('dispatcher', %w[store pubsub channels exceptions workers.count]) do
          build do |store, pubsub, channels, exceptions, count|
            Dispatcher.new(worker_count: count, store:, pubsub:, channels:, exceptions:, registry: Sidereal.registry)
          end
          start { |dispatcher, task| dispatcher.start(task) }
          stop(&:stop)
        end
        c.defer('dispatcher')

        # Doesn't depend on its targets: depending on a deferred component would defer it too
        c.declare('runner', DispatcherRunner)
        c.declare('runner.targets', T::Array[String]) { [[c.path, 'dispatcher'].compact.join('.')] }
        c.declare('runner.process', DispatcherProcess) { :all }
        c.component!('runner', %w[elector runner.process runner.targets]) do
          build do |elector, process, targets|
            DispatcherRunner.new(config: c.root, targets:, elector:, process:)
          end
          start { |runner, task| runner.start(task) }
          stop(&:stop)
        end

        # Depends on the runner to start after it (and so after the elector)
        c.declare('scheduler', SchedulerInterface)
        c.component!('scheduler', ['runner']) do
          build { |_runner| Sidereal.scheduler }
          start { |scheduler, task| scheduler.start(task) }
        end
      end
    end
  end
end
