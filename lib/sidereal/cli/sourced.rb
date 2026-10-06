# frozen_string_literal: true

require_relative 'installer'

module Sidereal
  module CLI
    # `sid sourced`: the Sourced integration — install it, and inspect it.
    #
    # `install` is built in, like {DB}, because it has to run in an app that
    # hasn't got Sourced yet. The commands that *read* an app's Sourced setup
    # need the integration loaded, so they register themselves into {.register}
    # from {Sidereal::Integrations::Sourced.setup} — one `sourced` namespace,
    # filled from both sides.
    class Sourced < Command
      TEMPLATES = File.expand_path('templates/sourced', __dir__)
      GITHUB = 'ismasan/sourced'
      BRANCH = 'ccc'

      # `sid sourced install`
      class Install < Command
        self.description = 'Set up Sourced: the gem, the sourced component and a database'

        options do
          option '--skip-bundle', "Don't run bundle install"
          option '--force', 'Overwrite files that already exist'
        end

        def call
          installer = Installer.new(app_root)
          # Sourced keeps the app's commands and events in its database, so it
          # has one installed first rather than setting up its own. In this
          # process rather than through bin/sid: a nested binstub would resolve
          # its own bundle, and there is nothing to gain from a second one.
          DB::Install.new(passed_through, name: 'install', output:).call
          print_actions installer.gems('sourced', github: GITHUB, branch: BRANCH,
                                                  comment: '# Durable, event-sourced storage.')
          print_actions installer.templates(TEMPLATES, self, overwrite: !!@options[:force])
          unless @options[:skip_bundle]
            run_in!(app_root, 'bundle', 'install')
            # In a separate process: Sourced renders its own migration, and the
            # gem has only just been bundled — this process's load path was
            # fixed before it existed.
            run_in!(app_root, 'bin/sid', 'sourced', 'migration', *[('--force' if @options[:force])].compact)
            # The store checks its tables are there rather than creating them,
            # so an app that hasn't migrated can't boot at all.
            run_in!(app_root, 'bin/sid', 'db', 'migrations', 'run')
          end
          instructions
        end

        private

        # Samovar underscores an option's key, so these can't be derived from
        # the flag names.
        def passed_through
          [('--skip-bundle' if @options[:skip_bundle]), ('--force' if @options[:force])].compact
        end

        def instructions
          terminal.puts
          terminal.puts 'Sourced ready.', style: :title
          terminal.puts
          if @options[:skip_bundle]
            terminal.puts "Then, once the gems are installed, write Sourced's migration and run it:"
            terminal.puts
            terminal.print_line :key, '  bin/sid sourced migration'
            terminal.print_line :key, '  bin/sid db migrations run'
          else
            terminal.puts "Sourced's tables are migrated. Register deciders and projectors in " \
                          'config/components/sourced.rb, and see what it does with:'
            terminal.puts
            terminal.print_line :key, '  bin/sid sourced topology'
          end
        end
      end

      # The commands under `sid sourced`, by the name they're typed as. The
      # same hash {Sourced} dispatches on, so a command registered after this
      # class is defined is still found — see {Sidereal::CLI.registry}.
      COMMANDS = { 'install' => Install }

      # Add a command to `sid sourced`.
      #
      # @param name [String]
      # @param command_class [Class<Command>]
      # @return [Class<Command>] command_class
      def self.register(name, command_class)
        COMMANDS[name] = command_class
      end

      self.description = "Install Sourced, and inspect the app's event-sourced design"

      nested :command, COMMANDS

      def call
        @command ? @command.call : print_usage
      end
    end
  end
end
