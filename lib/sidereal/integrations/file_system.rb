# frozen_string_literal: true

# Filesystem / unix-socket integration.
#
# Switches the store, pubsub, and elector to the single-machine, multi-process
# implementations in one call — the set needed to run across multiple worker
# processes on a single machine. Files and the pubsub socket live under +dir+
# (default ./storage, relative to the working directory — i.e. the app root when
# launched with `falcon host` from there).
#
# Applied via Sidereal's integration hook (or the {Sidereal::Configuration#use_file_system!}
# shorthand, which requires this file and delegates here):
#
#   Sidereal.configure do |c|
#     c.use Sidereal::Integrations::FileSystem            # dir: 'storage'
#     c.use Sidereal::Integrations::FileSystem, dir: 'tmp'
#   end
#
# Each is registered in {Sidereal::Configuration#dependencies} and built when
# first resolved (at the latest by {Sidereal::Host#start}), so override any
# individual collaborator afterward:
#
#   c.use_file_system!
#   c.store = Sourced.config.store   # keep the filesystem pubsub + elector

require 'sidereal/store/file_system'
require 'sidereal/pubsub/unix'
require 'sidereal/elector/file_system'

module Sidereal
  module Integrations
    # Backend integration wiring Sidereal's store + pubsub + elector to the
    # filesystem / unix-socket implementations. Called by
    # {Sidereal::Configuration#use}.
    module FileSystem
      # @param config [Sidereal::Configuration]
      # @param dir [String] base directory for store files, socket, and lock
      # @return [Sidereal::Configuration]
      def self.setup(config, dir: 'storage')
        deps = config.dependencies
        deps.register!('sidereal.store', override: true) do
          Store::FileSystem.new(root: File.join(dir, 'store'))
        end
        deps.register!('sidereal.elector', override: true) do
          Elector::FileSystem.new(lock_path: File.join(dir, 'leader.lock'))
        end
        # The broker role follows whichever elector is registered when the
        # pubsub is built, including one that replaces this one.
        deps.register!('sidereal.pubsub', ['sidereal.elector'], override: true) do |elector|
          PubSub::Unix.new(socket_path: File.join(dir, 'pubsub.sock'), elector:)
        end
        config
      end
    end
  end
end
