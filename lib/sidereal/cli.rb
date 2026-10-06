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

      # Called by an app's bin/sid: remembers the app's root, registers the
      # commands that only make sense inside an app, then loads the app —
      # changing into its root first, since paths like ./storage are relative
      # to it.
      #
      # Loading the app is what gives its integrations their turn: each one's
      # +setup+ runs as +boot.rb+ calls {Sidereal::Config::Root#use}, which is
      # where it registers its own commands and skills. That has to happen
      # before the command line is parsed, since Samovar resolves a command's
      # name then — before any command runs. Loading declares and implements
      # components but builds nothing, so nothing is connected to yet; a
      # command that needs component values calls {.boot_app!}.
      #
      # An app that fails to load is remembered rather than raised, so `--help`
      # and the commands that don't need the app still work — which is when the
      # command line is most wanted. {.boot_app!} re-raises for the rest.
      #
      # @param root [String] the app's root directory
      # @return [void]
      def load_app(root)
        @app_root = File.expand_path(root)
        register 'console', AppConsole
        register 'commands', Commands
        register 'skills', SkillsCommand

        Dir.chdir(@app_root)
        @app_load_error = nil
        begin
          require File.join(@app_root, 'boot')
        rescue ::Exception => e # rubocop:disable Lint/RescueException -- re-raised by boot_app!
          @app_load_error = e
          warn "sid: #{@app_root} failed to load: #{e.class}: #{e.message}"
          warn 'sid: only the commands that do not need the app are available.'
        end
      end

      # Build the app's components ({Sidereal.config}), so a command can read
      # any of them. Call it from a command that needs component values, after
      # it has parsed its own arguments — building opens connections (a
      # database, a socket), so `--help` and a bad command line never pay it.
      #
      # Starts nothing: no pubsub, no workers, no dispatcher, and no component's
      # +start+ hook. A command that needs a started component asks for it by
      # key with +Sidereal.config.start_component!+.
      #
      # @raise [Error] outside an app
      # @raise [Exception] whatever {.load_app} caught loading the app
      def boot_app!
        raise Error, 'Run this command from inside a Sidereal app, with bin/sid' unless app_root
        raise @app_load_error if @app_load_error

        Sidereal.config.build!
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
