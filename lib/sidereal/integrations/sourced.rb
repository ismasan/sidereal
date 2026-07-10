# frozen_string_literal: true

# Sourced ⇄ Sidereal integration.
#
# +require 'sidereal/integrations/sourced'+ from your boot file to run Sidereal
# on a {https://github.com/ismasan/sourced Sourced} backend — Sourced becomes a
# drop-in replacement for Sidereal's built-in store + dispatcher. Sidereal
# Commanders register and run on the Sourced runtime alongside Sourced Deciders,
# Projectors and any other reactor; one runtime appends and routes messages to
# all of them.
#
# **Commanders as Sourced reactors.** This file teaches {Sidereal::Commander} the
# Sourced reactor protocol: each commander is an *exclusive*, id-partitioned,
# delete-on-ack queue (one partition per command, concurrent, unordered — like
# Sidereal's worker pool). Its handler runs, dispatched follow-up commands are
# appended (or scheduled, for +.at+/+.in+), the command + its events are
# published to {Sidereal.pubsub}, and the handled command is deleted.
#
# **Exception bridge.** Registers {Sidereal.exceptions} as a subscriber on
# Sourced's error strategy, so every Sourced retry / terminal failure surfaces in
# Sidereal's exception registry (default toasts + +on_retry+/+on_failure+/
# +on_fatal+ subscribers). When Sourced is the dispatcher it owns retry/fail
# orchestration, so this bridge is what surfaces failures in the UI.
#
# Under the forking Falcon environment each worker loads boot.rb in its own
# process, so this registration (and Sourced's own store) is established fresh
# per worker. The dispatcher factory also calls {Sourced.setup!} on start,
# re-establishing connections for the current process — so a *callable* store
# (below) stays fork-safe even if the app is preloaded in the parent.
#
# Require this at load time (top-level in boot.rb), then apply it with Sidereal's
# integration hook — one call wires the store + dispatcher together:
#
#   require 'sidereal/integrations/sourced'
#
#   Sourced.configure { |c| c.store = Sequel.sqlite('db/app.db') }
#   Sourced.register(SomeDecider)   # deciders/projectors: registered as usual
#
#   Sidereal.configure do |c|
#     c.use_file_system!                     # pubsub + elector
#     c.use Sidereal::Integrations::Sourced  # store + dispatcher + error bridge
#   end
#
# Commander-only apps can let the integration configure Sourced's store too.
# Pass a callable factory so each forked worker opens its own connection:
#
#   Sidereal.configure do |c|
#     c.use_file_system!
#     c.use Sidereal::Integrations::Sourced, store: -> { Sequel.sqlite('db/app.db') }
#   end

require 'sourced'

module Sidereal
  # Teach Commanders the Sourced reactor protocol (duck-typed: Sourced only
  # needs +handled_messages+ and +handle_claim+; the rest get defaults, but we
  # override +exclusive?+ so commanders own and delete their command types).
  class Commander
    class << self
      # Commanders exclusively own their command types (Registry enforces one
      # commander per command) and delete each command on ack.
      def exclusive? = true

      # The message types this reactor handles (Sourced protocol).
      def handled_messages = handled_commands

      # Process a claimed batch. For each command: run the commander, then emit
      # Sourced action signals to (1) append/schedule the dispatched follow-up
      # commands, (2) publish the command + its events to Sidereal's pubsub after
      # the store transaction commits, and (3) delete the handled command.
      def handle_claim(claim)
        claim.messages.map do |cmd|
          result = handle(cmd, pubsub: Sidereal.config.pubsub)
          # build_for splits follow-ups by created_at: immediate :append vs
          # future :schedule (a .at/.in command carries a future created_at).
          signals = ::Sourced::Actions.build_for(result.commands, source: cmd)
          signals << { type: :after_sync, work: -> { publish_result(result) } }
          signals << { type: :ack, delete: true }
          [signals, cmd]
        end
      end

      # Publish the handled command and its dispatched events to Sidereal's
      # pubsub. Mirrors Sidereal::Dispatcher#publish; runs post-commit via an
      # :after_sync signal so nothing publishes if the append/delete rolls back.
      def publish_result(result)
        pubsub = Sidereal.config.pubsub
        pubsub.publish(Sidereal.channels.for(result.msg), result.msg)
        result.events.each { |evt| pubsub.publish(Sidereal.channels.for(evt), evt) }
      rescue StandardError => ex
        Sidereal.exceptions.report_fatal(exception: ex)
      end
    end
  end

  module Integrations
    # Backend integration wiring Sidereal to Sourced (store + dispatcher). Apply
    # it in one call via Sidereal's integration hook:
    #
    #   Sidereal.configure do |c|
    #     c.use_file_system!                     # pubsub + elector
    #     c.use Sidereal::Integrations::Sourced  # store + dispatcher + error bridge
    #   end
    #
    module Sourced
      # Sidereal only ever calls #append on the store. Delegating to
      # +::Sourced.store+ (rather than capturing it once) means a per-process
      # reconnect — {::Sourced.setup!} re-running the store's configure block
      # after a fork — is picked up automatically, so a forked worker appends
      # through its own live connection.
      module StoreProxy
        module_function

        def append(...) = ::Sourced.store.append(...)
      end

      # Wire Sidereal's store + dispatcher to Sourced, and bridge Sourced's
      # retry/failure reporting to Sidereal's exception registry. Called by
      # {Sidereal::Configuration#use}.
      #
      # @param config [Sidereal::Configuration]
      # @param store [#call, Sequel::Database, nil] when given, configures
      #   Sourced's store. Prefer a callable factory (e.g.
      #   +-> { Sequel.sqlite(path) }+): it is registered as a Sourced configure
      #   block, so {::Sourced.setup!} re-runs it to open a fresh connection per
      #   process — fork-safe even if the app is preloaded in the parent. A bare
      #   Sequel::Database is reused as-is (fine when each worker loads its config
      #   fresh, but not fork-safe under preload). When nil, the already-configured
      #   Sourced store is used.
      # @return [Sidereal::Configuration]
      def self.setup(config, store: nil)
        # A Proc is a store factory (re-run per process for fork-safety); a
        # Sequel::Database is used as-is. (Don't use respond_to?(:call): a
        # Sequel::Database responds to #call — prepared-statement invocation.)
        ::Sourced.configure { |c| c.store = store.is_a?(Proc) ? store.call : store } if store
        config.store      = StoreProxy
        config.dispatcher = Dispatcher

        # Report Sourced's retry / terminal-failure events to Sidereal's exception
        # registry (report_retry / report_failure — the object-callback interface
        # Sourced's error strategy accepts). Since Sourced owns retry/fail
        # orchestration here, this is what surfaces failures in the UI.
        ::Sourced.config.error_strategy.on_retry Sidereal.exceptions
        ::Sourced.config.error_strategy.on_fail Sidereal.exceptions
        config
      end

      # Dispatcher factory for +config.dispatcher+. Registers every Sidereal
      # commander with Sourced (once, with its full command set) and then starts
      # Sourced's runtime, which routes to commanders, deciders and any reactor.
      # Registering here (rather than hooking Sidereal.register) means all
      # +command+ declarations are complete before registration.
      module Dispatcher
        # @param task [Async::Task]
        # @return [Sourced::Dispatcher] the running dispatcher (Host keeps it to #stop)
        def self.start(task)
          # Re-establish Sourced's store/connections (and re-register reactors)
          # for this — possibly just-forked — process before starting. With a
          # callable store this opens a fresh connection per worker even when the
          # app was preloaded in the parent; a redundant no-op reconnect when each
          # worker already loaded its config fresh.
          ::Sourced.setup!
          Sidereal.registry.commanders.each do |commander|
            ::Sourced.register(commander) unless ::Sourced.router.reactors.include?(commander)
          end
          ::Sourced::Dispatcher.start(task)
        end
      end
    end
  end
end
