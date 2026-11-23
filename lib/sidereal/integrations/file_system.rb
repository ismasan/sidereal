# frozen_string_literal: true

# Filesystem / unix-socket integration.
#
# Switches the store, pubsub, and elector to the single-machine, multi-process
# implementations in one call — the set needed to run across multiple worker
# processes on a single machine. Files and the pubsub socket live under +dir+
# (default ./storage, relative to the working directory — i.e. the app root when
# launched with `falcon host` from there).
#
# Applied with {Sidereal::Config::Root#use} (or the
# {Sidereal::Config::Root#use_file_system!} shorthand, which requires this file
# and delegates here):
#
#   Sidereal.config.use Sidereal::Integrations::FileSystem             # dir: 'storage'
#   Sidereal.config.use Sidereal::Integrations::FileSystem, dir: 'tmp'
#
# It implements +sidereal.store+, +sidereal.elector+ and +sidereal.pubsub+,
# each built when the process starts, and adds `bin/sid store` to inspect the
# store's messages and requeue or delete them (see {Sidereal::CLI::StoreCommand}).
# Re-implement any of the components afterwards to keep the others:
#
#   Sidereal.config.use_file_system!
#   Sidereal.config.use Sidereal::Integrations::Sourced, db: 'db' # Sourced's store

require 'sidereal/store/file_system'
require 'sidereal/pubsub/unix'
require 'sidereal/elector/file_system'

module Sidereal
  module Integrations
    # Backend integration wiring Sidereal's store + pubsub + elector to the
    # filesystem / unix-socket implementations. Called by {Sidereal::Config::Root#use}.
    module FileSystem
      # Builds the file system store. A named provider rather than a block, so
      # {.store?} can tell this store from one that replaced it without
      # building either.
      StoreProvider = Data.define(:root) do
        def call = Store::FileSystem.new(root:)
      end

      # Whether +sidereal.store+ is still the store this integration
      # implemented, and not one an integration or the app used after it.
      # Reads the configuration only: nothing is built.
      #
      # @param config [Sourced::Component] the app's root, see {Sidereal.config}
      # @return [Boolean]
      def self.store?(config)
        config.declared?('sidereal.store') &&
          config.node('sidereal.store').implementation&.provider.is_a?(StoreProvider)
      end

      # @param config [Sourced::Component] the app's root, see {Sidereal.config}
      # @param dir [String] base directory for store files, socket, and lock
      # @return [Sourced::Component]
      def self.setup(config, dir: 'storage')
        config.component!('sidereal.store', StoreProvider.new(File.join(dir, 'store')))
        config.component!('sidereal.elector') do
          build { Elector::FileSystem.new(lock_path: File.join(dir, 'leader.lock')) }
          start { |elector, task| elector.start(task) }
        end
        # The broker role follows whichever elector implements sidereal.elector
        # when the pubsub is built, including one that replaces this one.
        config.component!('sidereal.pubsub', ['sidereal.elector']) do
          build { |elector| PubSub::Unix.new(socket_path: File.join(dir, 'pubsub.sock'), elector:) }
          start { |pubsub, task| pubsub.start(task) }
        end
        register_cli
        config
      end

      # `bin/sid store`. Into a process-global registry, so it's idempotent
      # under a repeated +use+. An integration used later can replace the
      # store, so `bin/sid` only offers the command if this store is still the
      # app's once it has loaded (see {Sidereal::CLI::StoreCommand.available?}).
      # @return [void]
      def self.register_cli
        require 'sidereal/cli/store'
        Sidereal::CLI.register 'store', Sidereal::CLI::StoreCommand
      end
    end
  end
end
