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
# **One runtime per host.** The integration sets
# +config.dispatcher_process = :leader+, so only the process the elector
# promotes runs the Sourced runtime (commanders, deciders, projectors). SQLite
# serializes writers, so N runtimes on N workers would queue on each other;
# pinning the consuming side to one process lets the other workers serve pages
# and queries in parallel. Every worker still appends commands through
# {StoreProxy} — those writes are not serialized, the handler and projection
# writes are. Set +c.dispatcher_process = :all+ after +use+ to fan out again.
#
# **Cross-process wake-ups.** Sourced's store announces appends through a
# notifier and its dispatcher listens on it, but the default notifier is
# in-process — a follower's append would only reach the leader on the next
# catch-up poll. The integration configures Sourced with {Notifier}, which
# carries those announcements over {Sidereal.pubsub}, so with the unix-socket
# pubsub an append on any worker wakes the leader's workers at once.
#
# Under the forking Falcon environment each worker loads boot.rb in its own
# process, so this registration (and Sourced's own store) is established fresh
# per worker. The integration also registers {Sourced.setup!} as a boot hook
# ({Sidereal::Configuration#on_boot}), which {Sidereal::Host#start} runs in
# every process, leader or follower, before anything starts: it re-establishes
# connections for the current process — so a *callable* store (below) stays
# fork-safe even if the app is preloaded in the parent — installs the store's
# tables and recompiles its codec against every message type the app has
# loaded, so a follower that only appends is as ready as the leader that
# consumes.
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
      # pubsub. Runs post-commit via an :after_sync signal so nothing publishes
      # if the append/delete rolls back.
      def publish_result(result)
        Integrations::Sourced.publish_messages([result.msg, *result.events])
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
      # Publish each message to Sidereal's pubsub on its resolved channel. The
      # single publish body shared by every Sourced→Sidereal path (Commander
      # action-signal, Decider/Projector after_sync). Publish/resolver failures
      # are terminal here — the store transaction has already committed, so a
      # retry would double-apply — hence they funnel to +report_fatal+ rather
      # than raising into the worker fiber.
      def self.publish_messages(messages)
        messages.each { |msg| Sidereal.pubsub.publish(Sidereal.channels.for(msg), msg) }
      rescue StandardError => ex
        Sidereal.exceptions.report_fatal(exception: ex)
      end

      # Sidereal only ever calls #append on the store. Delegating to
      # +::Sourced.store+ (rather than capturing it once) means a per-process
      # reconnect — {::Sourced.setup!} re-running the store's configure block
      # after a fork — is picked up automatically, so a forked worker appends
      # through its own live connection. The store is ready to append in every
      # process because {Sourced.setup} registers +::Sourced.setup!+ as a boot
      # hook; a process without a Host (a rake task calling
      # +Sidereal.dispatch!+) calls +::Sourced.setup!+ itself, once.
      module StoreProxy
        module_function

        def append(...) = ::Sourced.store.append(...)
      end

      # Wire Sidereal's store + dispatcher to Sourced, pin the dispatcher to
      # the elected leader, route Sourced's append notifications over
      # Sidereal's pubsub, and bridge Sourced's retry/failure reporting to
      # Sidereal's exception registry. Called by {Sidereal::Configuration#use}.
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
        # A configure block, not a one-off assignment: Sourced.setup! replays
        # these after a fork, and the store resolves the configured notifier on
        # every append, so ordering against the app's own store block is moot.
        ::Sourced.configure { |c| c.notifier = Notifier.new }
        config.store              = StoreProxy
        config.dispatcher         = Dispatcher
        config.dispatcher_process = :leader
        # Every process appends, only the leader consumes: prepare Sourced's
        # store (connection, tables, codec) at boot everywhere, not just where
        # the dispatcher starts. Runs once per process: +::Sourced.setup!+
        # rebuilds the store from the configure blocks and freezes the
        # configuration afterwards.
        #
        # The store's codec is then recompiled, because +::Sourced.configure+
        # compiles it when it runs — in boot.rb, before the app has defined its
        # message types — and the codec is a process-wide singleton whose
        # +compile!+ is a no-op once compiled. At boot every type is loaded,
        # and +recompile!+ is incremental (pairs are cached per message class),
        # so it builds only what the early compile could not see.
        config.on_boot do
          ::Sourced.setup!
          ::Sourced.store.message_codec.recompile!
        end

        # Report Sourced's retry / terminal-failure events to Sidereal's exception
        # registry (report_retry / report_failure — the object-callback interface
        # Sourced's error strategy accepts). Since Sourced owns retry/fail
        # orchestration here, this is what surfaces failures in the UI.
        ::Sourced.config.error_strategy.on_retry Sidereal.exceptions
        ::Sourced.config.error_strategy.on_fail Sidereal.exceptions
        config
      end

      # What {Notifier} puts on the wire: one Sourced store announcement.
      # A plain message rather than a {System::Notification} — it is never a
      # command, so no commander should register a handler for it.
      StoreNotification = Sidereal::Message.define('sidereal.sourced.store_notification') do
        attribute :event_name, Sidereal::Types::String
        attribute :value, Sidereal::Types::String
      end

      # Sourced store notifier over {Sidereal.pubsub}. Implements the interface
      # of +Sourced::InlineNotifier+ (+Sourced::Configuration::NotifierInterface+):
      # the store calls +notify_new_messages+ / +notify_reactor_resumed+ after
      # each commit, and the Sourced dispatcher subscribes its queuer and runs
      # +start+ in a fiber of its own.
      #
      # Announcements travel as {StoreNotification} messages on a fixed channel,
      # bypassing the channel-name resolvers. With {PubSub::Unix} the leader
      # hears its own appends through local delivery and the other workers'
      # through the broker; with {PubSub::Memory} this is the inline behaviour
      # with one queue hop. Outside an Async reactor (a rake task calling
      # +Sidereal.dispatch!+) the unix pubsub has no socket, so the frame is
      # dropped and Sourced's catch-up poll picks the messages up instead —
      # the poll remains the safety net either way.
      class Notifier
        CHANNEL = 'sidereal.sourced.store_notification'

        def initialize
          @subscribers = []
          @channel = nil
        end

        # @param callable [#call] receives +(event_name, value)+, both Strings
        # @return [void]
        def subscribe(callable)
          @subscribers << callable
        end

        # @param types [Array<String>] appended message types
        # @return [void]
        def notify_new_messages(types)
          publish('messages_appended', types.uniq.join(','))
        end

        # @param group_id [String] consumer group of the resumed reactor
        # @return [void]
        def notify_reactor_resumed(group_id)
          publish('reactor_resumed', group_id)
        end

        # Subscribe and forward every announcement to the subscribers. Blocks
        # until {#stop}, like the Postgres listener Sourced models this on.
        # @return [void]
        def start
          @channel = Sidereal.pubsub.subscribe(CHANNEL)
          @channel.start do |msg, _ch|
            @subscribers.each { |s| s.call(msg.payload.event_name, msg.payload.value) }
          end
        end

        # @return [void]
        def stop
          channel = @channel
          @channel = nil
          channel&.stop
        end

        private

        # The append has already committed, so a failure here must not raise
        # into the appending fiber: report it and let the catch-up poll cover
        # the lost wake-up.
        def publish(event_name, value)
          Sidereal.pubsub.publish(CHANNEL, StoreNotification.new(payload: { event_name:, value: }))
        rescue StandardError => ex
          Sidereal.exceptions.report_fatal(exception: ex)
        end
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
          # Sourced is already set up for this process: the boot hook that
          # {Sourced.setup} registers ran +::Sourced.setup!+ before the Host
          # started anything. It is not called again here — +::Sourced.setup!+
          # freezes the configuration, so it runs once per process. A dispatcher
          # driven without a Host (tests, CLIs) calls it before this.
          Sidereal.registry.commanders.each do |commander|
            ::Sourced.register(commander) unless ::Sourced.router.reactors.include?(commander)
          end
          ::Sourced::Dispatcher.start(task)
        end
      end

      # Auto-generate a "projected" signal event for every Sourced Projector and
      # publish it after each committed batch — so Pages re-fetch the read model
      # without the projector hand-writing an event class, an +after_sync+ block,
      # or a channel string.
      #
      # Prepended onto +Sourced::Projector.singleton_class+, so it wraps the
      # +partition_by+ macro for the base +StateStored+/+EventSourced+ classes and
      # every subclass (singleton-class inheritance resolves the prepend live, even
      # though those subclasses were defined before this integration loaded).
      #
      # The signal carries one attribute per partition key (any arity — e.g.
      # +partition_by(:student_id, :course_id)+ yields a two-attribute signal), and
      # its payload comes from the projector instance's +partition_values+ (the full
      # claimed tuple), so the app's +channel_name+ resolver routes it exactly like
      # the domain events it partitions by.
      #
      # A batch may hold messages from several causal chains, so one signal is
      # published per distinct +correlation_type+ in the batch, each correlated
      # from the last message of that chain. The signal then carries a real
      # lineage — causation, correlation and +correlation_type+ — and a page
      # that reacts to the root command (a rendered form, or a block-less
      # +on+) reloads when the read model it feeds is committed, with no
      # reaction written for the signal itself.
      #
      module ProjectorSignals
        def partition_by(*keys)
          super
          __define_projection_signal(partition_keys)
        end

        # @param keys [Array<Symbol>] resolved partition keys (set by +super+)
        def __define_projection_signal(keys)
          return if keys.empty? || const_defined?(:Projected, false)

          type = "#{Sidereal::Utils.snake_case(name)}.projected" # e.g. "campaigns_projector.projected"
          signal = ::Sourced::Event.define(type) do
            # These events are dynamically defined here. Make sure attributes are serializable.
            keys.each { |k| attribute k, ::Sourced::Types::Lax::String }
          end
          const_set(:Projected, signal) # Pages reference MyProjector::Projected

          after_sync do |messages: [], **|
            vals = partition_values # instance accessor: the full claimed tuple
            next if vals.empty? || vals.each_value.any?(&:nil?)

            last_by_root = messages.each_with_object({}) { |msg, by_root| by_root[msg.correlation_type] = msg }
            signals = last_by_root.each_value.map { |source| source.correlate(signal.new(payload: vals)) }
            Sidereal::Integrations::Sourced.publish_messages(signals)
          end
        end
      end
    end
  end
end

# --- Page.on sources (runs at require time, before domain reactors load) ---

# A page can react to a whole reactor: +on(Donation)+ expands through
# +sidereal_events+ (see Sidereal::Page.on). A decider stands for the events
# that change its state — its evolve list, its own events and any foreign ones
# it evolves — since that is what a page showing that state wants to follow.
# Sourced keeps no static record of what a decider emits, and the evolve list
# is the better answer anyway. A projector stands for its Projected signal, the
# one message that says its read model committed; reloading on the events it
# consumes would read the model before the batch lands.
::Sourced::Decider.define_singleton_method(:sidereal_events) { handled_messages_for_evolve }
::Sourced::Projector.define_singleton_method(:sidereal_events) do
  const_defined?(:Projected, false) ? [const_get(:Projected)] : []
end

# --- Auto-publish wiring (runs at require time, before domain reactors load) ---

# Deciders: publish the domain events they emitted. Copied into every app decider
# via +Sync::ClassMethods#inherited+ (registered here, before subclasses exist).
# The reaction branch passes +events: []+ → no-op. The events arrive already
# correlated to the command (+Decider.handle_batch+ does that before its sync
# hooks run), so subscribers see the +correlation_type+ they match on.
::Sourced::Decider.after_sync do |events: [], **|
  Sidereal::Integrations::Sourced.publish_messages(events)
end

# Projectors: auto-generate + publish a "projected" signal from partition_by.
::Sourced::Projector.singleton_class.prepend(Sidereal::Integrations::Sourced::ProjectorSignals)
