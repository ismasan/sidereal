# frozen_string_literal: true

require 'async'
require_relative 'sidereal/version'
require_relative 'sidereal/types'

module Sidereal
  class Error < StandardError; end
  # Your code goes here...

  DispatcherInterface = Types::Interface[:start]
  PubsubInterface = Types::Interface[:start, :subscribe, :publish]
  # Sidereal apps only append to stores
  # It's up to dispatcher implementations how to use the store to claim commands
  # Ex. Sourced's store has a more sophisticated claim mechanism than Sidereal::Store
  StoreWriterInterface = Types::Interface[:append]

  def self.message_method_name(prefix, name)
    "__handle_#{prefix}_#{name.split('::').map(&:downcase).join('_')}"
  end

  def self.setup!
  end

  class Configuration
    attr_accessor :workers
    attr_reader :store, :pubsub, :dispatcher

    def initialize(workers: 25)
      @workers = workers
      @pubsub = PubSub::Memory.instance
      @store = Store::Memory.instance
      @dispatcher = Sidereal::Dispatcher
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
  end

  def self.config
    @config ||= Configuration.new
  end

  def self.configure(&)
    yield config
  end

  def self.registry
    @registry ||= Registry.new
  end

  def self.reset_registry!
    @registry = nil
  end

  def self.register(commander)
    commander.handled_commands.each do |cmd_class|
      registry[cmd_class] = commander
    end
  end

  def self.pubsub = config.pubsub
  def self.store = config.store
  def self.dispatcher = config.dispatcher

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
      in [MessageInterface => m]
        m
    end

    store.append(cmd)
  end
end

require_relative 'sidereal/message'
require_relative 'sidereal/system'
require_relative 'sidereal/router'
require_relative 'sidereal/components/layout'
require_relative 'sidereal/page'
require_relative 'sidereal/pubsub/memory'
require_relative 'sidereal/store'
require_relative 'sidereal/store/memory'
require_relative 'sidereal/registry'
require_relative 'sidereal/dispatcher'
require_relative 'sidereal/app'
require_relative 'sidereal/components/command'
