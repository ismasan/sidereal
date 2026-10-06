# frozen_string_literal: true

require 'samovar'
require 'console/terminal'
require 'sidereal/version'

module Sidereal
  # The `sid` command line interface.
  module CLI
    # Raised by a command to stop with a message and a non-zero exit status.
    class Error < StandardError; end

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

    require_relative 'cli/new'
    require_relative 'cli/app_console'
    require_relative 'cli/commands'
    require_relative 'cli/skills'

    class << self
      # The root directory of the app `sid` is running in, set by
      # {.load_app}. Nil outside an app.
      attr_reader :app_root

      # The commands `sid` can run, keyed by the name they are typed as. The
      # top-level {Application} dispatches on this very hash, so a command
      # registered after it is defined is still found.
      #
      # @return [Hash{String => Class<Command>}]
      def registry
        @registry ||= {}
      end

      # Add a command to `sid`, under the name it is typed as. A command is a
      # {Command} subclass, and can nest sub-commands of its own.
      #
      #   Sidereal::CLI.register 'deploy', MyApp::CLI::Deploy
      #
      # @param name [String]
      # @param command_class [Class<Command>]
      # @return [Class<Command>] command_class
      def register(name, command_class)
        registry[name] = command_class
      end

      # Called by an app's bin/sid: remembers the app's root and registers
      # the commands that only make sense inside an app, including those of
      # integrations the app's bundle includes (`sourced` for Sourced). The
      # app itself is loaded by the commands that need it ({.boot_app!}), so
      # `bin/sid --help` stays fast.
      #
      # @param root [String] the app's root directory
      def load_app(root)
        @app_root = File.expand_path(root)
        register 'console', AppConsole
        register 'commands', Commands
        register 'skills', SkillsCommand

        # Integrations add their own commands, for apps that bundle them.
        if Gem.loaded_specs.key?('sourced')
          require 'sidereal/integrations/sourced/cli'
          Integrations::Sourced::CLI.install
        end
      end

      # Load the app as a server worker has it: change into its root, since
      # paths like ./storage are relative to it, require its boot.rb, then
      # build its components ({Sidereal.config}), so a command can read any of
      # them. Building opens connections but starts nothing: no pubsub, no
      # workers, no dispatcher.
      #
      # @param build [Boolean] false to load the app's code only, without
      #   connecting to anything
      # @raise [Error] outside an app
      def boot_app!(build: true)
        raise Error, 'Run this command from inside a Sidereal app, with bin/sid' unless app_root

        Dir.chdir(app_root)
        require File.join(app_root, 'boot')
        Sidereal.config.build! if build
      end
    end

    # The commands available outside an app. {.load_app} adds the rest.
    register 'info', Info
    register 'new', New

    # The top-level `sid` command.
    class Application < Command
      # Parse and run the command line. Returns true on success and false on
      # a parse error or a CLI::Error, so the result can be passed straight
      # to `exit`.
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
      rescue Error => error
        Console::Terminal.for(output).tap do |terminal|
          terminal[:error] = terminal.style(:red, nil, :bold)
        end.puts(error.message, style: :error)
        false
      end

      self.description = 'Sidereal command line'

      options do
        option '-h/--help', 'Print usage'
      end

      nested :command, CLI.registry

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
