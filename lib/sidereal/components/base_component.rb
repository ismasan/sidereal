# frozen_string_literal: true

require 'phlex'
require 'securerandom'
require_relative 'datastar_helpers'

module Sidereal
  module Components
    class BaseComponent < Phlex::HTML
      include DatastarHelpers

      private

      def params
        context.request.env.fetch('router.params', BLANK_HASH)
      end

      private def command(klass, *args, &block)
        render Sidereal::Components::Command.new(klass, *args, &block)
      end

      def dom_id(prefix)
        [prefix, SecureRandom.hex(4)].join('-')
      end
    end
  end
end
