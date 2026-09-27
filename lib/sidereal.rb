# frozen_string_literal: true

require 'async'
require 'console'
require_relative 'sidereal/logging' # quiets benign SSE-disconnect task warnings
require_relative 'sidereal/version'
require_relative 'sidereal/types'
require_relative 'sidereal/utils'
require 'sidereal/single_process'

module Sidereal
  class Error < StandardError; end

  # Raised by a build where builds are forbidden: see {.lock!}
  class ForkError < Error; end

  def self.message_method_name(prefix, name)
    "__handle_#{prefix}_#{name.split('::').map(&:downcase).join('_')}"
  end

  # Sidereal's own components (see {Config}): the store, pubsub, elector,
  # dispatcher and the rest. Mounted at +sidereal+ in {.config}.
  #
  # @return [Sourced::Component]
  def self.component
    @component ||= Config.build
  end

  # The app's root component: Sidereal's components under +sidereal+ (see
  # {Config}), whatever integrations mount (ex. Sourced, under +sourced+) and
  # the app's own components, ex. a +db+ its classes inject with +dep :db+.
  #
  #   Sidereal.config.declare('db', Sequel::Database)
  #   Sidereal.config.component!('db') do
  #     build { Sequel.sqlite('app.db') }
  #     teardown(&:disconnect)
  #   end
  #   Sidereal.config.config!('sidereal.workers.count') { 10 }
  #
  # Integrations mount and implement components in it (see {Config::Root#use}):
  #
  #   Sidereal.config.use_file_system!
  #   Sidereal.config.use Sidereal::Integrations::Sourced, db: 'db'
  #
  # Values are read once it's built: {Host#start} starts it (building it
  # first) in every process. CLIs, consoles and specs call
  # +Sidereal.config.build!+ before reading anything.
  #
  # @return [Config::Root]
  def self.config
    @config ||= Config::Root.new.tap { |root| root.mount('sidereal', component) }
  end

  # Drop {.config} and {.component}: the next access builds fresh, open
  # defaults. For specs, which start each example from unwired components;
  # {.reload!} deliberately keeps them.
  def self.reset_config!
    @config = nil
    @component = nil
  end

  # Make any build of {.config} in this process raise {ForkError}. The Falcon
  # service calls it in its controller before preloading the app: the app's
  # code and component declarations are shared with the workers it forks, but
  # nothing may be built there (a connection would be shared across
  # processes). Each worker builds its own when its host starts.
  #
  # Not the lock {.config} takes when it's prepared: declaring and implementing
  # components still work, only building raises.
  #
  # @param pid [Integer] the process where builds are forbidden
  # @return [void]
  def self.lock!(pid = Process.pid)
    config.notifier.subscribe('root.building') do
      next unless Process.pid == pid

      raise ForkError, "Sidereal.config can't be built in process #{pid}: it forks the processes that build it. " \
                       'Read components when a process starts, not while the app loads.'
    end
  end

  def self.registry
    @registry ||= Registry.new
  end

  def self.reset_registry!
    @registry = nil
  end

  # Drop every process-global that application classes register into as they
  # load — the commander registry, the channel-name resolvers, the exception
  # subscribers, and the compiled message codec. Each is emptied (or reset to
  # its defaults), ready to be filled again by the next generation of classes.
  #
  # Call it after (re)loading app classes: tests do so between examples, and it
  # is the hook a development-mode class reloader would use, so a redefined
  # commander or message type doesn't leave the previous one registered.
  #
  # {.config} is deliberately untouched. It holds deployment wiring — an open
  # store, a connected pubsub, an elected leader, a database connection — none
  # of which is derived from app classes, and all of which would be expensive
  # and disruptive to rebuild every time code changes.
  #
  # @return [self]
  def self.reload!
    reset_registry!
    reset_channels!
    reset_exceptions!
    reset_message_codec!
    self
  end

  def self.scheduler
    @scheduler ||= Scheduler.new
  end

  def self.reset_scheduler!
    @scheduler = nil
  end

  # Process-global channel-name registry. System notifications
  # ({Sidereal::System::NotifyRetry} / {NotifyFailure}) are delivered by
  # the exceptions registry's default publisher on the failed command's
  # channel, never through user resolvers; {Channels.with_system_defaults}
  # also keeps a defensive bypass route for them, so user-supplied
  # resolvers stay free of system-message branches.
  def self.channels
    @channels ||= Channels.with_system_defaults
  end

  # Reset {.channels} to its defaults, in place: the +sidereal.channels+
  # component, once built, holds the same object.
  def self.reset_channels!
    @channels&.restore_defaults!
  end

  # Install a channel-name registry. For hosts and tests that need resolution to
  # go through a registry they control; {.reset_channels!} restores the default.
  #
  # @param channels [Sidereal::Channels]
  def self.channels=(channels)
    @channels = channels
  end

  # Process-global exception-subscriber registry. Backends call
  # +report_retry+ / +report_failure+ when their retry/fail policy
  # fires; pre-installed default publishers turn each report into
  # a {Sidereal::System::Notify*} message broadcast on the failed
  # command's channel.
  def self.exceptions
    @exceptions ||= Exceptions.with_default_publisher
  end

  # Reset {.exceptions} to its defaults, in place: the +sidereal.exceptions+
  # component, once built, holds the same object.
  def self.reset_exceptions!
    @exceptions&.restore_defaults!
  end

  # Process-global serializer for Sidereal's own transports ({Store::FileSystem},
  # {PubSub::Unix}), shared so they compile their pairs once. Each of them compiles
  # it from its own +#start+, which is where a message type the format cannot
  # represent fails.
  #
  # {Sourced::Message::JSONCodec} comes from the sourced-message gem and encodes whole
  # messages — envelope included — which is what a file body or a socket frame needs.
  # Sourced's store has its own subclass, so it keeps its own +.default+ and registry;
  # the two compile separately over the same +Plumb::Codec::JSON+ format, so an
  # encoder registered there serves both.
  def self.message_codec
    Sourced::Message::JSONCodec.default
  end

  def self.reset_message_codec!
    Sourced::Message::JSONCodec.reset!
  end

  def self.register(commander)
    commander.handled_commands.each do |cmd_class|
      registry[cmd_class] = commander
    end
  end

  def self.pubsub = config['sidereal.pubsub']
  def self.store = config['sidereal.store']
  def self.elector = config['sidereal.elector']

  # Labels of the subsystems whose state lives entirely within one process
  # (they carry the {SingleProcess} marker). These break cross-process fan-out
  # under a forking host, so the list drives {.check_topology!}. Empty once
  # every subsystem is cross-process safe, ex. after {Config::Root#use_file_system!}.
  #
  # @param config [Sourced::Component] a built root, see {.config}
  # @return [Array<String>] ex. +["pubsub", "elector"]+
  def self.single_process_subsystems(config = self.config)
    %w[store pubsub elector].select { |key| config["sidereal.#{key}"].is_a?(SingleProcess) }
  end

  # Fail fast at startup when in-process-only subsystems are configured in a
  # multi-process (forked-worker) deployment, where their in-memory state isn't
  # shared and cross-process SSE fan-out silently breaks. Logs a loud,
  # multi-line error and terminates the process — refusing to boot into a
  # broken topology is safer than serving requests that appear to work but
  # never propagate updates across workers.
  #
  # A no-op for a single worker or once every subsystem is cross-process safe
  # (e.g. after {Config::Root#use_file_system!}). Hosts that fork (the Falcon
  # environment) call this with their worker-process count; single-process
  # hosts needn't. Builds +config+ to see what was configured.
  #
  # @param process_count [Integer] number of forked worker processes
  #
  # @param config [Sourced::Component] the root to inspect (defaults to the
  #   process-global {.config}; injected in tests)
  # @return [void] returns only when the topology is safe; otherwise exits
  def self.check_topology!(process_count, config: self.config)
    return if process_count.to_i <= 1

    config.build!
    subsystems = single_process_subsystems(config)
    return if subsystems.empty?

    verb = subsystems.one? ? 'is' : 'are'
    Console.error(self, <<~MSG.chomp, subsystems: subsystems, process_count: process_count)
      Refusing to boot: in-process-only subsystem(s) in a multi-process deployment.

      This host is starting #{process_count} worker processes, but these subsystems
      keep their state in memory within a single process:

          #{subsystems.join(', ')} #{verb} in-process-only

      Across forked workers this silently breaks the app:
        - SSE updates published in one worker never reach browsers on another worker.
        - Every worker believes it is the leader, so background/scheduled work double-runs.

      Fix (pick one):
        - For single-node, multi-process: call `Sidereal.config.use_file_system!` while the app loads, BEFORE any
          other `Sidereal.config.use` — switches to the unix-socket pubsub + file-lock elector.
        - Or run a single worker process (e.g. `count 1` in falcon.rb).
    MSG

    exit(1)
  end

  # Build a {Host} that boots {.config}. Call after all app classes have
  # loaded, so the registries are fully populated before the host's start
  # locks them.
  #
  # @return [Host]
  def self.new_host
    Host.new(config:)
  end

  # Build (if needed) and append a command to the configured {.store} from
  # outside the request/handler lifecycle. Use this from CLIs, consoles,
  # rake tasks, schedulers, or any code that needs to enqueue a command
  # without an existing causation chain.
  #
  # Three call shapes are supported via pattern matching:
  #
  # @overload dispatch!(message_class, payload)
  #   Build a new command from a class and a payload hash. The payload is
  #   validated by {Sidereal::Message}'s schema; invalid input raises.
  #   @param message_class [Class<Sidereal::Message>] command class
  #   @param payload [Hash] payload attributes
  #
  # @overload dispatch!(message_class)
  #   Build a new command with no payload (relies on the message class's
  #   defaults).
  #   @param message_class [Class<Sidereal::Message>] command class
  #
  # @overload dispatch!(message)
  #   Append an already-built message instance. Use this when you need to
  #   set custom +metadata+, +correlation_id+, or +causation_id+ before
  #   enqueueing.
  #   @param message [Sidereal::Message] a fully-built message
  #
  # Appends to {.store}, so {.config} must be built: a CLI or rake task calls
  # +Sidereal.config.build!+ first.
  #
  # @return [true] from {Sidereal::Store#append}
  # @raise [Sourced::Component::NotBuiltError] if {.config} isn't built
  # @raise [NoMatchingPatternError] if +args+ doesn't match any shape above
  # @raise [Plumb::ParseError] if the payload fails validation
  #
  # @example
  #   Sidereal.dispatch!(AddTodo, title: 'Buy milk')
  #   Sidereal.dispatch!(Tick)  # no-payload command
  #   Sidereal.dispatch!(AddTodo.new(payload: { title: 'x' }, metadata: { channel: 'todos.42' }))
  def self.dispatch!(*args)
    cmd = case args
      in [Class => c, Hash => payload]
        c.parse(payload:)
      in [Class => c]
        c.parse(Plumb::BLANK_HASH)
      in [Sourced::Message => m]
        m
    end

    store.append(cmd)
  end
end

require_relative 'sidereal/message'
require_relative 'sidereal/forms_codec'
require_relative 'sidereal/system'
require_relative 'sidereal/channels'
require_relative 'sidereal/exceptions'
require_relative 'sidereal/router'
require_relative 'sidereal/components/layout'
require_relative 'sidereal/page'
require_relative 'sidereal/pubsub/memory'
require_relative 'sidereal/store'
require_relative 'sidereal/store/memory'
require_relative 'sidereal/registry'
require_relative 'sidereal/dispatcher'
require_relative 'sidereal/elector'
require_relative 'sidereal/scheduler'
require_relative 'sidereal/config'
require_relative 'sidereal/dispatcher_runner'
require_relative 'sidereal/deps'
require_relative 'sidereal/host'
require_relative 'sidereal/app'
require_relative 'sidereal/components/command'
require_relative 'sidereal/skills'
