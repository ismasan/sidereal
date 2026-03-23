# frozen_string_literal: true

require 'phlex'
require 'securerandom'
require_relative 'datastar_helpers'

module Sidereal
  class BaseComponent < Phlex::HTML
    include DatastarHelpers

    private

    def dom_id(prefix)
      [prefix, SecureRandom.hex(4)].join('-')
    end
  end
end
