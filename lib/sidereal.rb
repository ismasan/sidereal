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

  class Configuration < Struct.new(:workers)
  end

  def self.config
    @config ||= Configuration.new(1)
  end

  def self.configure(&)
    yield config
    config.freeze
  end

  def self.registry
    @registry ||= []
  end

  def self.register(app)
    registry << app.commander
  end

  def self.pubsub
    PubSub::Memory.instance
  end

  def self.store
    Store::Memory.instance
  end
end

require_relative 'sidereal/types'
require_relative 'sidereal/message'
require_relative 'sidereal/router'
require_relative 'sidereal/page'
require_relative 'sidereal/pubsub/memory'
require_relative 'sidereal/store/memory'
require_relative 'sidereal/app'
require_relative 'sidereal/components/command'
