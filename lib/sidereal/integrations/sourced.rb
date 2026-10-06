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
# **One runtime per host.** The integration sets +sidereal.runner.process+
# to +:leader+, so only the process the elector promotes runs the Sourced
# runtime (commanders, deciders, projectors). SQLite serializes writers, so N
# runtimes on N workers would queue on each other; pinning the consuming side
# to one process lets the other workers serve pages and queries in parallel.
# Every worker still appends commands to Sourced's store — those writes are not
# serialized, the handler and projection writes are. Implement
# +sidereal.runner.process+ as +:all+ after +use+ to fan out again.
#
# **Cross-process wake-ups.** Sourced's store announces appends through a
# notifier and its dispatcher listens on it, but the default notifier is
# in-process — a follower's append would only reach the leader on the next
# catch-up poll. The integration implements +sourced.notifier+ with
# {Notifier}, which carries those announcements over +sidereal.pubsub+, so
# with the unix-socket pubsub an append on any worker wakes the leader's
# workers at once.
#
# **Components.** Sourced's configuration is mounted at +sourced+ in
# {Sidereal.config}, and boots with it: preparing compiles its store's codec
# (once before forking, if the app is preloaded and prepared there), and every
# process builds and starts Sourced's components (its store installs its
# tables on start, so a follower that only appends is as ready as the leader).
# Only the leader starts its dispatcher. The app can implement any of them,
# ex. +Sidereal.config.config!('sourced.workers.count') { 4 }+.
#
# Require this at load time, then apply it with {Sidereal::Config::Root#use}. +db:+ names a
# component of the app's that Sourced's store uses, built in each process when
# it starts (so never shared across a fork):
#
#   require 'sidereal/integrations/sourced'
#
#   Sidereal.config.declare('db', Sequel::Database)
#   Sidereal.config.component!('db') do
#     build { Sequel.sqlite('db/app.db') }
#     teardown(&:disconnect)
#   end
#
#   Sidereal.config.use_file_system!                              # pubsub + elector
#   Sidereal.config.use Sidereal::Integrations::Sourced, db: 'db' # store + dispatcher + error bridge
#   Sourced.register(SomeDecider)                          # deciders/projectors: registered as usual

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
          result = handle(cmd, pubsub: Sidereal.pubsub)
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
    # Backend integration wiring Sidereal to Sourced (store + dispatcher).
    # Apply it with {Sidereal::Config::Root#use}:
    #
    #   Sidereal.config.use_file_system!                              # pubsub + elector
    #   Sidereal.config.use Sidereal::Integrations::Sourced, db: 'db' # store + dispatcher + error bridge
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

      # Mount Sourced in the app's root, and wire the two:
      #
      # - +sourced.db+ is the app's +db+ component, when given.
      # - +sourced.notifier+ carries store announcements over +sidereal.pubsub+.
      # - +sidereal.store+ is Sourced's store: Sidereal only appends to it.
      # - +sourced.dispatcher+, which routes to commanders, deciders and every
      #   other reactor, is deferred and is the runner's target
      #   (+sidereal.runner.targets+): Sidereal's runner starts it on the elected
      #   leader only (+sidereal.runner.process+ is +:leader+) and stops it
      #   on demotion, rather than Sourced starting it in every process.
      #   Sidereal's own dispatcher stays deferred, and never starts.
      # - +sidereal.sourced.exceptions+ reports Sourced's retries and terminal failures
      #   to {Sidereal.exceptions}. Sourced owns retry/fail orchestration here,
      #   so this is what surfaces failures in the UI.
      # - Sidereal's commanders are registered with Sourced as the tree is
      #   prepared, once every app class has loaded.
      # - `bin/sid sourced` and the sidereal-sourced agent skill are registered
      #   with {Sidereal::CLI} and {Sidereal.skills}. The app's bin/sid loads it
      #   before parsing the command line, so this is in time for either.
      #
      # @param config [Sourced::Component] the app's root, see {Sidereal.config}
      # @param db [String, Symbol, nil] the key of a component in +config+ whose
      #   value is the Sequel::Database Sourced keeps its messages in. The app's
      #   component owns the connection, and disconnects it if it implements a
      #   teardown. When nil, Sourced's own +db+ is used.
      # @return [Sourced::Component]
      def self.setup(config, db: nil)
        register_cli_and_skills
        config.mount('sourced', ::Sourced)
        config.alias('sourced.db', db.to_s) if db
        config.config!('sourced.notifier', ['sidereal.pubsub', 'sidereal.exceptions']) do |pubsub, exceptions|
          Notifier.new(pubsub:, exceptions:)
        end
        config.alias('sidereal.store', 'sourced.store')

        # Deferred, so booting doesn't start it in every process: Sidereal's runner
        # starts it by key on the leader, and stops it on demotion. It can start
        # again after stopping, so a process can be promoted more than once.
        config.defer('sourced.dispatcher')
        config.config!('sidereal.runner.targets') { ['sourced.dispatcher'] }
        config.config!('sidereal.runner.process') { :leader }

        # Built before anything starts, so before Sourced's router freezes the
        # strategy on start. Whatever strategy the app implements is kept.
        # Declared in Sidereal's tree, which owns its keys, and implemented from
        # the root, which can see Sourced's
        config.node('sidereal').declare('sourced.exceptions', ::Sourced::Config::ErrorStrategyInterface)
        config.config!('sidereal.sourced.exceptions', ['sourced.error_strategy', 'sidereal.exceptions']) do |strategy, exceptions|
          strategy.on_retry(exceptions).on_fail(exceptions)
        end

        # Commanders are declared under sourced.reactors, which Sourced's router
        # collects when the tree is prepared: after that, the tree is locked.
        # root.preparing is published just before, while it's still open.
        config.notifier.subscribe('root.preparing') { register_commanders }
        config
      end

      # The two things an app gets by configuring this integration that aren't
      # components: `bin/sid sourced` and the skill describing it. Both land in
      # process-global registries, so both are idempotent under a repeated
      # +use+. The CLI file only defines command classes — it doesn't load
      # Sourced, which the commands do for themselves via +boot_app!+.
      # @return [void]
      def self.register_cli_and_skills
        require 'sidereal/integrations/sourced/cli'
        # Fully qualified: inside this module a bare CLI is this integration's,
        # which shadows Sidereal::CLI.
        # Into Sidereal's own `sourced` namespace, beside its `install` — which
        # is built in, since it has to run before Sourced is configured.
        Sidereal::CLI::Sourced.register 'topology', Sidereal::Integrations::Sourced::CLI::Topology
        Sidereal.skills.add('sidereal-sourced', File.expand_path('sourced/skills/sidereal-sourced', __dir__))
      end

      # Register every Sidereal commander with Sourced, with its full command
      # set (the app classes have loaded by the time the tree is prepared).
      # Skips commanders the app registered itself, which have a +group_id+
      # once registered.
      # @return [void]
      def self.register_commanders
        Sidereal.registry.commanders.each do |commander|
          next if commander.respond_to?(:group_id) && ::Sourced.config.declared?(::Sourced::Config.reactor_key(commander))

          ::Sourced.register(commander)
        end
      end

      # What {Notifier} puts on the wire: one Sourced store announcement.
      # A plain message rather than a {System::Notification} — it is never a
      # command, so no commander should register a handler for it.
      StoreNotification = Sidereal::Message.define('sidereal.sourced.store_notification') do
        attribute :event_name, Sidereal::Types::String
        attribute :value, Sidereal::Types::String
      end

      # Sourced store notifier over Sidereal's pubsub. Implements the interface
      # of +Sourced::InlineNotifier+ (+Sourced::Config::NotifierInterface+):
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
      #
      # {#stop} and {#start} can alternate: Sourced's dispatcher stops and
      # starts it with each demotion and promotion, and its subscribers stay.
      class Notifier
        CHANNEL = 'sidereal.sourced.store_notification'

        # @param pubsub [#publish, #subscribe] Sidereal's pubsub
        # @param exceptions [#report_fatal] where publish failures are reported
        def initialize(pubsub:, exceptions:)
          @pubsub = pubsub
          @exceptions = exceptions
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
          @channel = @pubsub.subscribe(CHANNEL)
          @channel.start do |msg, _ch|
            @subscribers.each { |s| s.call(msg.payload.event_name, msg.payload.value) }
          end
        end

        # Stop forwarding, until {#start} runs again.
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
          @pubsub.publish(CHANNEL, StoreNotification.new(payload: { event_name:, value: }))
        rescue StandardError => ex
          @exceptions.report_fatal(exception: ex)
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

# --- Dependency injection (runs at require time) ---

# +dep :db+ in a decider or projector, as in a Sidereal::Commander: Sourced
# builds an instance per claimed batch with +new(partition_values)+, which the
# injected +initialize+ passes through, so +dep+ readers work in +state+,
# +evolve+, +command+, +reaction+ and +sync+ blocks. Extending the base
# classes' singletons reaches every subclass, defined before or after this.
::Sourced::Decider.extend(Sidereal::Deps)
::Sourced::Projector.extend(Sidereal::Deps)

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
