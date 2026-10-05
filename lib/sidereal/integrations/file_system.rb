# frozen_string_literal: true

# Filesystem / unix-socket integration.
#
# Switches the store, pubsub, and elector to the single-machine, multi-process
# implementations in one call — the set needed to run across multiple worker
# processes on a single machine. Files and the pubsub socket live under +dir+
# (default ./storage, relative to the working directory — i.e. the app root when
# launched with `falcon host` from there).
#
# Applied with {Sidereal.use} (or the {Sidereal.use_file_system!} shorthand,
# which requires this file and delegates here):
#
#   Sidereal.use Sidereal::Integrations::FileSystem             # dir: 'storage'
#   Sidereal.use Sidereal::Integrations::FileSystem, dir: 'tmp'
#
# It implements +sidereal.store+, +sidereal.elector+ and +sidereal.pubsub+,
# each built when the process starts, so re-implement any of them afterwards
# to keep the others:
#
#   Sidereal.use_file_system!
#   Sidereal.use Sidereal::Integrations::Sourced, db: 'db' # Sourced's store

require 'sidereal/store/file_system'
require 'sidereal/pubsub/unix'
require 'sidereal/elector/file_system'

module Sidereal
  module Integrations
    # Backend integration wiring Sidereal's store + pubsub + elector to the
    # filesystem / unix-socket implementations. Called by {Sidereal.use}.
    module FileSystem
      # @param config [Sourced::Component] the app's root, see {Sidereal.config}
      # @param dir [String] base directory for store files, socket, and lock
      # @return [Sourced::Component]
      def self.setup(config, dir: 'storage')
        config.config!('sidereal.store') do
          Store::FileSystem.new(root: File.join(dir, 'store'))
        end
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
        config
      end
    end
  end
end
