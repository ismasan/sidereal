# frozen_string_literal: true

require 'phlex'
require 'securerandom'
require_relative 'datastar_helpers'

module Sidereal
  module Components
    class BaseComponent < Phlex::HTML
      BLANK_HASH = {}.freeze
      include DatastarHelpers

      # Fiber-local slot holding the machine that command forms rendered inside
      # {#with_machine} must be valid for. Fiber-local for the same reason as
      # {Page::RENDERING_KEY}.
      MACHINE_KEY = :__sidereal_rendering_machine__

      # The machine set by the innermost {#with_machine} in this fiber, or +nil+.
      def self.current_machine = Thread.current[MACHINE_KEY]

      # Render every instance of this component, and its subclasses, inside
      # {#with_machine}, with the machine +reader+ returns.
      #
      # @example
      #   class BookingPage < Sidereal::Page
      #     with_machine { @booking }
      #   end
      def self.with_machine(&reader)
        raise ArgumentError, 'with_machine needs a block returning the machine' unless reader

        @machine_reader = reader
      end

      def self.machine_reader
        @machine_reader || (superclass.machine_reader if superclass.respond_to?(:machine_reader))
      end

      private def around_template(&block)
        reader = self.class.machine_reader
        return super unless reader

        with_machine(instance_exec(&reader)) { super(&block) }
      end

      # Render the block with +machine+ as the current machine: any command form
      # rendered inside it raises {Sidereal::CommandNotAvailableError} unless
      # +machine+ accepts that command in its current state. Restores the
      # previous machine afterwards, so the innermost one wins.
      #
      # @param machine [Sourced::Machine]
      private def with_machine(machine)
        unless machine.respond_to?(:available_commands)
          raise ArgumentError, "#{machine.inspect} is not a machine: it doesn't respond to #available_commands"
        end

        previous = Thread.current[MACHINE_KEY]
        Thread.current[MACHINE_KEY] = machine
        begin
          yield
        ensure
          Thread.current[MACHINE_KEY] = previous
        end
      end

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
