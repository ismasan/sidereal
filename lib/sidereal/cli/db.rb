# frozen_string_literal: true

require 'fileutils'
require_relative '../utils'
require_relative 'installer'

module Sidereal
  module CLI
    # `sid db`: the app's database — set one up, and migrate it.
    #
    # A built-in rather than an integration registering itself (see
    # {CLI.load_app}): `db install` has to run in an app that has no database
    # yet, so there is no configuration for it to be registered from. Sequel is
    # the app's dependency, not Sidereal's — and `db install` is what adds it —
    # so it is required inside the commands that use it, never as this loads.
    class DB < Command
      TEMPLATES = File.expand_path('templates/db', __dir__)
      MIGRATIONS_DIR = 'db/migrations'
      # Sequel's sqlite adapter needs the sqlite3 gem beside it.
      GEMS = %w[sequel sqlite3].freeze
      # What `sid new` already ships in .gitignore; written for apps without it.
      IGNORED = ['/storage/*', '!/storage/.keep'].freeze
      # 14 digits, which is what makes Sequel pick its TimestampMigrator and
      # order migrations chronologically — the filenames sort as strings.
      TIMESTAMP = '%Y%m%d%H%M%S'

      # `sid db install`
      class Install < Command
        self.description = "Set up a SQLite database: the db component, db/migrations and the gems"

        options do
          option '--skip-bundle', "Don't run bundle install"
          option '--force', 'Overwrite files that already exist'
        end

        def call
          installer = Installer.new(app_root)
          print_actions installer.gems(*GEMS, comment: "# The app's database. See config/components/db.rb.")
          print_actions installer.ignore(*IGNORED)
          print_actions installer.templates(TEMPLATES, self, overwrite: !!@options[:force])
          bundle!(installer) unless @options[:skip_bundle]
          instructions
        end

        private

        # The gems just added aren't in the lock file yet, so this is also what
        # makes them usable.
        def bundle!(installer)
          terminal.puts
          terminal.print_line :key, '  run  ', :reset, 'bundle install'
          installer.run!('bundle', 'install')
        end

        def instructions
          terminal.puts
          terminal.puts 'Database ready.', style: :title
          terminal.puts
          terminal.print_line :key, '  bin/sid db migrations add create_things'
          terminal.print_line :key, '  bin/sid db migrations run'
          terminal.puts
          terminal.puts "Classes reach the connection with `dep :db`. Edit config/components/db.rb to move it."
        end
      end

      # `sid db migrations`
      class Migrations < Command
        # Shared by the three migration commands.
        module Helpers
          # Sequel's migrator, pinned to the timestamp one. +Sequel::Migrator.run+
          # would sniff the directory instead, and it picks the *integer*
          # migrator for an empty one — which then refuses to run at all. Since
          # `migrations add` only ever writes 14-digit names, the timestamp
          # migrator is always the right choice.
          def migrator(**opts)
            require 'sequel/core'
            ::Sequel.extension :migration
            ::Sequel::TimestampMigrator.new(database, migrations_path, **opts)
          end

          # Building the components is what opens the connection, so this is
          # also where an app that fails to load reports it.
          def database
            @database ||= begin
              CLI.boot_app!
              unless Sidereal.config.declared?('db')
                raise Error, "This app has no 'db' component — run `bin/sid db install`"
              end

              Sidereal.config['db']
            end
          end

          def migrations_path = File.join(app_root, MIGRATIONS_DIR)

          def migration_files = Dir[File.join(migrations_path, '*.rb')].sort

          def no_migrations
            terminal.puts "No migrations in #{MIGRATIONS_DIR}. " \
                          'Add one with `bin/sid db migrations add <name>`.'
          end
        end

        # `sid db migrations add <name>`
        class Add < Command
          self.description = 'Create a timestamped migration file'

          # Not `name`: Samovar::Command#name is the command's own name, so
          # `one :name` would always be set, to "add".
          one :migration_name, 'What the migration does, e.g. create_things'

          BODY = <<~RUBY
            # frozen_string_literal: true

            Sequel.migration do
              change do
                # create_table(:things) do
                #   primary_key :id
                #   String :name, null: false
                # end
              end
            end
          RUBY

          def call
            raise Error, 'Name the migration, e.g. `bin/sid db migrations add create_things`' unless @migration_name

            slug = Utils.snake_case(@migration_name)
            raise Error, "#{@migration_name.inspect} doesn't make a usable file name" if slug.empty?

            FileUtils.mkdir_p(File.join(app_root, MIGRATIONS_DIR))
            path = File.join(MIGRATIONS_DIR, "#{Time.now.utc.strftime(TIMESTAMP)}_#{slug}.rb")
            File.write(File.join(app_root, path), BODY)
            terminal.print_line :key, '  create  ', :reset, path
          end
        end

        # `sid db migrations run`
        class Run < Command
          include Helpers

          self.description = 'Apply every migration that has not run yet'

          def call
            return no_migrations if migration_files.empty?

            pending = migrator.migration_tuples.map { |_migration, file, _direction| file }
            return terminal.puts 'Already up to date.' if pending.empty?

            migrator.run
            pending.each { |file| terminal.print_line :key, '  migrate   ', :reset, file }
          end
        end

        # `sid db migrations rollback`
        class Rollback < Command
          include Helpers

          self.description = 'Roll back the migration that ran last'

          def call
            return no_migrations if migration_files.empty?

            # A migration recorded in the database but deleted from disk would
            # otherwise raise before we could say which one it was.
            applied = migrator(allow_missing_migration_files: true).applied_migrations.last
            return terminal.puts 'No applied migrations to roll back.' if applied.nil?

            # schema_migrations holds downcased basenames, so match on that
            # rather than joining the recorded name onto the directory.
            path = migration_files.find { |file| File.basename(file).downcase == applied }
            raise Error, "#{applied} has been applied but is no longer in #{MIGRATIONS_DIR}" unless path

            ::Sequel::TimestampMigrator.run_single(database, path,
                                                   direction: :down, allow_missing_migration_files: true)
            terminal.print_line :key, '  rollback  ', :reset, File.basename(path)
          end
        end

        self.description = "Create and run the app's database migrations"

        nested :command, { 'add' => Add, 'run' => Run, 'rollback' => Rollback }

        def call
          @command ? @command.call : print_usage
        end
      end

      self.description = "Set up and migrate the app's database"

      nested :command, { 'install' => Install, 'migrations' => Migrations }

      def call
        @command ? @command.call : print_usage
      end
    end
  end
end
