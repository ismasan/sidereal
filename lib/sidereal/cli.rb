# frozen_string_literal: true

require 'samovar'
require 'console/terminal'
require 'sidereal/version'

module Sidereal
  # The `sid` command line interface.
  module CLI
    # Base class for all `sid` commands.
    class Command < Samovar::Command
      # Styled terminal writing to this command's output stream.
      # Falls back to plain text when output is not a TTY.
      def terminal
        @terminal ||= Console::Terminal.for(output).tap do |terminal|
          terminal[:title] = terminal.style(nil, nil, :bold)
          terminal[:key] = terminal.style(:cyan)
          terminal[:error] = terminal.style(:red, nil, :bold)
        end
      end
    end

    # `sid info`: print Sidereal and Ruby versions.
    class Info < Command
      self.description = 'Show Sidereal and Ruby versions'

      def call
        terminal.print_line :key, 'sidereal'.ljust(10), :reset, Sidereal::VERSION
        terminal.print_line :key, 'ruby'.ljust(10), :reset, RUBY_DESCRIPTION
      end
    end

    # The top-level `sid` command.
    class Application < Command
      def self.registry
        @_registry ||= {}
      end

      def self.register(name, command_class)
        registry[name] = command_class
      end

      # Parse and run the command line. Returns true on success and false on
      # a parse error, so the result can be passed straight to `exit`.
      # A `--help` token a sub-command doesn't declare prints that command's
      # usage and counts as success.
      def self.call(arguments = ARGV, output: $stderr)
        parse(arguments).call
        true
      rescue Samovar::Error => error
        error.command.print_usage(output: output) do |formatter|
          formatter.map(error)
        end
        error.is_a?(Samovar::InvalidInputError) && error.help?
      end

      self.description = 'Sidereal command line'

      options do
        option '-h/--help', 'Print usage'
      end

      register 'info', Info

      nested :command, registry

      def call
        if @options[:help] || @command.nil?
          print_usage
        else
          @command.call
        end
      end
    end
  end
end
