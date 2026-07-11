# frozen_string_literal: true

require 'async'
require_relative 'sidereal/version'
require_relative 'sidereal/types'
require_relative 'sidereal/utils'

module Sidereal
  class Error < StandardError; end
  # Your code goes here...

  DispatcherInterface = Types::Interface[:start]
  PubsubInterface = Types::Interface[:start, :subscribe, :publish]
  ElectorInterface = Types::Interface[:start, :on_promote, :on_demote, :leader?]
  # Sidereal apps only append to stores
  # It's up to dispatcher implementations how to use the store to claim commands
  # Ex. Sourced's store has a more sophisticated claim mechanism than Sidereal::Store
  StoreWriterInterface = Types::Interface[:append]
  # A backend integration self-applies to a Configuration via #setup(config, **opts).
  # See Configuration#use.
  IntegrationInterface = Types::Interface[:setup]

  def self.message_method_name(prefix, name)
    "__handle_#{prefix}_#{name.split('::').map(&:downcase).join('_')}"
  end

  class Configuration
    attr_accessor :workers
    attr_reader :store, :pubsub, :dispatcher, :elector

    def initialize(workers: 25)
      @workers = workers
      @pubsub = PubSub::Memory.instance
      @store = Store::Memory.instance
      @dispatcher = Sidereal::Dispatcher
      @elector = Elector::AlwaysLeader.new
    end

    def store=(s)
      @store = StoreWriterInterface.parse(s)
    end

    def pubsub=(p)
      @pubsub = PubsubInterface.parse(p)
    end

    def dispatcher=(d)
      @dispatcher = DispatcherInterface.parse(d)
    end

    def elector=(e)
      @elector = ElectorInterface.parse(e)
    end

    # Switch the store, pubsub, and elector to the filesystem / unix-socket
    # implementations in one call — the set needed to run across multiple
    # worker processes on a single machine. Files and the pubsub socket
    # live under +dir+ (default ./storage, relative to the working
    # directory — i.e. the app root when launched with `falcon host` from
    # there).
    #
    # Override any individual collaborator afterward:
    #
    #   c.use_file_system!
    #   c.store = Sourced.config.store   # keep the filesystem pubsub + elector
    #
    # @param dir [String] base directory for store files, socket, and lock
    # @return [self]
    def use_file_system!(dir: 'storage')
      require 'sidereal/integrations/file_system'
      use(Integrations::FileSystem, dir:)
    end

    # Apply a backend integration in one call. The integration's +#setup+ wires
    # whatever collaborators it provides (e.g. a store + dispatcher pair, plus any
    # bridging). Like {#use_file_system!} it returns +self+ and can be called in or
    # out of a {Sidereal.configure} block.
    #
    #   c.use Sidereal::Integrations::Sourced                  # reads Sourced.config.store
    #   c.use Sidereal::Integrations::Sourced, store: sequel_db # configures Sourced too
    #
    # @param integration [#setup] responds to +setup(config, **opts)+
    # @return [self]
    def use(integration, **opts)
      IntegrationInterface.parse(integration).setup(self, **opts)
      self
    end
  end

  def self.config
    @config ||= Configuration.new
  end

  # Yield the process-global {.config} to a block. Apps call this once at
  # load time (top-level in boot.rb) to point Sidereal at a store,
  # dispatcher, etc. Under the forking Falcon environment each worker
  # loads boot.rb in its own process, so the block runs fresh per worker
  # and fork-unsafe collaborators (DB connections) are established anew —
  # no replay machinery needed.
  def self.configure(&)
    yield config
  end

  def self.registry
    @registry ||= Registry.new
  end

  def self.reset_registry!
    @registry = nil
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

  def self.reset_channels!
    @channels = nil
  end

  # Process-global exception-subscriber registry. Backends call
  # +report_retry+ / +report_failure+ when their retry/fail policy
  # fires; pre-installed default publishers turn each report into
  # a {Sidereal::System::Notify*} message broadcast on the failed
  # command's channel.
  def self.exceptions
    @exceptions ||= Exceptions.with_default_publisher
  end

  def self.reset_exceptions!
    @exceptions = nil
  end

  def self.register(commander)
    commander.handled_commands.each do |cmd_class|
      registry[cmd_class] = commander
    end
  end

  def self.pubsub = config.pubsub
  def self.store = config.store
  def self.dispatcher = config.dispatcher
  def self.elector = config.elector

  # Build a {Host} wired to the process-global collaborators from
  # {.config} (plus the {.channels} / {.exceptions} registries). Call
  # after all app classes have loaded, so the registries are fully
  # populated before {Host#start} freezes them.
  #
  # @return [Host]
  def self.new_host
    Host.new(
      channels:,
      exceptions:,
      elector:,
      pubsub:,
      dispatcher:,
      scheduler:
    )
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
  # @return [true] from {Sidereal::Store#append}
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
require_relative 'sidereal/host'
require_relative 'sidereal/app'
require_relative 'sidereal/components/command'
