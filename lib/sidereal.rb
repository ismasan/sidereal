# frozen_string_literal: true

require 'async'
require_relative 'sidereal/version'

module Sidereal
  class Error < StandardError; end
  # Your code goes here...

  def self.message_method_name(prefix, name)
    "__handle_#{prefix}_#{name.split('::').map(&:downcase).join('_')}"
  end

  def self.setup!
  end

  class Configuration
    attr_accessor :workers
    attr_writer :store, :pubsub, :dispatcher

    def initialize(workers: 1)
      @workers = workers
    end

    def store
      @store || Store::Memory.instance
    end

    def pubsub
      @pubsub || PubSub::Memory.instance
    end

    def dispatcher
      @dispatcher || Dispatcher
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
end

require_relative 'sidereal/types'
require_relative 'sidereal/message'
require_relative 'sidereal/router'
require_relative 'sidereal/components/layout'
require_relative 'sidereal/page'
require_relative 'sidereal/pubsub/memory'
require_relative 'sidereal/store/memory'
require_relative 'sidereal/registry'
require_relative 'sidereal/dispatcher'
require_relative 'sidereal/app'
require_relative 'sidereal/components/command'
