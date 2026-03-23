# frozen_string_literal: true

require 'async'
require_relative 'sidereal/version'

module Sidereal
  class Error < StandardError; end
  # Your code goes here...

  def self.message_method_name(prefix, name)
    "__handle_#{prefix}_#{name.split('::').map(&:downcase).join('_')}"
  end
end

require_relative 'sidereal/types'
require_relative 'sidereal/message'
require_relative 'sidereal/router'
require_relative 'sidereal/page'
require_relative 'sidereal/pubsub/memory'
require_relative 'sidereal/app'
