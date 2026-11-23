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
  #   broadcaster         Sidereal::Broadcaster: publishes transient messages on
  #                       the pubsub, on their resolved channel
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
  #   secret_key_base     the app's master secret: SIDEREAL_SECRET, or else
  #                       storage/secret.txt, created on first build. See
  #                       KeyGenerator.file_secret
  #   secrets             KeyGenerator: derives a key for each purpose from
  #                       secret_key_base
  #   signer              Signer, with the key secrets derive for it: signs the
  #                       URLs of pages' live updates
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
    BroadcasterInterface = T::Interface[:broadcast]
    # Started and stopped by the runner, possibly more than once per process
    DispatcherInterface = T::Interface[:start, :stop]
    SchedulerInterface = T::Interface[:start]
    SignerInterface = T::Interface[:generate, :verify]
    SecretsInterface = T::Interface[:derive]
    SecretKeyBase = T::String.where(bytesize: KeyGenerator::MIN_SECRET_BYTES..)
    # Where secret_key_base comes from when SIDEREAL_SECRET isn't set, relative
    # to the working directory, like the file system store's storage/.
    SECRET_FILE = 'storage/secret.txt'
    # Which process runs the dispatcher: every process, or only the one the
    # elector promotes. See DispatcherRunner.
    DispatcherProcess = T::Value[:all] | T::Value[:leader]

    # A backend integration applies itself to a root via +#setup(config, **opts)+.
    # See Root#use.
    IntegrationInterface = T::Interface[:setup]

    # The app's root component, {Sidereal.config}: a Sourced::Component, with
    # helpers to apply integrations to it.
    class Root < Sourced::Component
      # Apply a backend integration, which mounts and implements components in
      # this root.
      #
      #   Sidereal.config.use Sidereal::Integrations::FileSystem, dir: 'storage'
      #   Sidereal.config.use Sidereal::Integrations::Sourced, db: 'db'
      #
      # Integrations that implement the same component replace each other's:
      # the last one wins.
      #
      # @param integration [#setup] responds to +setup(config, **opts)+
      # @return [self]
      def use(integration, **opts)
        IntegrationInterface.parse(integration).setup(self, **opts)
        self
      end

      # Switch the store, pubsub, and elector to the filesystem / unix-socket
      # implementations in one call: the set needed to run across multiple
      # worker processes on a single machine. Files and the pubsub socket live
      # under +dir+ (default ./storage, relative to the working directory).
      # See {Integrations::FileSystem}.
      #
      # @param dir [String] base directory for store files, socket, and lock
      # @return [self]
      def use_file_system!(dir: 'storage')
        require 'sidereal/integrations/file_system'
        use(Integrations::FileSystem, dir:)
      end
    end

    # A fresh, open tree, with defaults for every component.
    # @return [Sourced::Component]
    def self.build
      Sourced::Component.new.tap do |c|
        c.declare('elector', ElectorInterface, description: 'Picks and signals the lead process')
        c.component!('elector') do
          build { Elector::AlwaysLeader.new }
          start { |elector, task| elector.start(task) }
        end

        c.declare('pubsub', PubsubInterface,
                  description: 'Delivers published messages to their subscribers, such as open pages')
        c.component!('pubsub', ['elector']) do
          build { |_elector| PubSub::Memory.instance }
          start { |pubsub, task| pubsub.start(task) }
        end

        c.declare('store', StoreWriterInterface,
                  description: 'Where dispatched commands are appended, for the dispatcher to consume') { Store::Memory.instance }

        c.declare('channels', ChannelsInterface,
                  description: 'Resolves the pubsub channel each message is published on')
        c.component!('channels') do
          build { Sidereal.channels }
          start { |channels, _| channels.lock! }
        end

        c.declare('exceptions', ExceptionsInterface,
                  description: 'Reports the exceptions handlers raise, as they are retried or fail')
        c.component!('exceptions') do
          build { Sidereal.exceptions }
          start { |exceptions, _| exceptions.lock! }
        end

        c.declare('broadcaster', BroadcasterInterface,
                  description: 'Publishes transient messages on the pubsub, on their channel')
        c.component!('broadcaster', %w[pubsub channels]) do
          build { |pubsub, channels| Broadcaster.new(pubsub:, channels:) }
        end

        c.declare('workers.count', T::Integer[0..],
                  description: 'How many worker fibers the dispatcher runs') { 25 }

        # Deferred, so the root's start doesn't start it in every process: the runner does
        c.declare('dispatcher', DispatcherInterface,
                  description: 'Consumes the store and runs the handlers for each command')
        c.component!('dispatcher', %w[store pubsub channels exceptions broadcaster workers.count]) do
          build do |store, pubsub, channels, exceptions, broadcaster, count|
            Dispatcher.new(worker_count: count, store:, pubsub:, channels:, exceptions:, broadcaster:, registry: Sidereal.registry)
          end
          start { |dispatcher, task| dispatcher.start(task) }
          stop(&:stop)
        end
        c.defer('dispatcher')

        # Doesn't depend on its targets: depending on a deferred component would defer it too
        c.declare('runner', DispatcherRunner,
                  description: 'Starts its targets in the processes that run them, and stops them on demotion')
        c.declare('runner.targets', T::Array[String],
                  description: 'Keys of the deferred components the runner starts and stops') { [[c.path, 'dispatcher'].compact.join('.')] }
        c.declare('runner.process', DispatcherProcess,
                  description: 'Which processes run the targets: :all, or only the :leader') { :all }
        c.component!('runner', %w[elector runner.process runner.targets]) do
          build do |elector, process, targets|
            DispatcherRunner.new(config: c.root, targets:, elector:, process:)
          end
          start { |runner, task| runner.start(task) }
          stop(&:stop)
        end

        # Depends on the runner to start after it (and so after the elector)
        c.declare('scheduler', SchedulerInterface,
                  description: "Dispatches the commands of the app's named schedules, on the leader process")
        c.component!('scheduler', ['runner']) do
          build { |_runner| Sidereal.scheduler }
          start { |scheduler, task| scheduler.start(task) }
        end

        c.declare('secret_key_base', SecretKeyBase,
                  description: "The app's master secret, which every other key is derived from") do
          secret = ENV['SIDEREAL_SECRET'].to_s
          secret.empty? ? KeyGenerator.file_secret(File.expand_path(SECRET_FILE)) : secret
        end

        c.declare('secrets', SecretsInterface,
                  description: 'Derives a key for each purpose from secret_key_base')
        c.config!('secrets', ['secret_key_base']) { |base| KeyGenerator.new(base) }

        c.declare('signer', SignerInterface,
                  description: "Signs and verifies the URLs of pages' live updates")
        c.config!('signer', ['secrets']) { |secrets| Signer.new(secrets.derive('sidereal.signer')) }
      end
    end
  end
end
