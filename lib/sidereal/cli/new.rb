# frozen_string_literal: true

require_relative 'generator'

module Sidereal
  module CLI
    # `sid new NAME`: generate a new Sidereal app.
    class New < Command
      TEMPLATES = File.expand_path('templates/new', __dir__)
      NAME_FORMAT = /\A[a-z][a-z0-9_]*\z/
      SIDEREAL_GITHUB = 'ismasan/sidereal'
      SOURCED_GITHUB = 'ismasan/sourced'
      SOURCED_BRANCH = 'ccc'
      PORT = 9292

      # What the templates see: `<%= title %>`, `<% if sourced? %>`, etc.
      Context = Data.define(:app_name, :title, :sidereal_path, :rspec, :sourced) do
        def rspec? = rspec
        def sourced? = sourced
        def port = PORT
        def sidereal_gem
          if sidereal_path
            "gem 'sidereal', path: '#{sidereal_path}'"
          else
            "gem 'sidereal', github: '#{SIDEREAL_GITHUB}'"
          end
        end
        def sourced_gem = "gem 'sourced', github: '#{SOURCED_GITHUB}', branch: '#{SOURCED_BRANCH}'"
      end

      self.description = 'Create a new Sidereal app'

      # Not `name`: Samovar::Command#name is the command's own name.
      one :path, 'Where to create the app. Its last part names it, e.g. my_app', pattern: /\A[^-]/

      options do
        option '-h/--help', 'Print usage'
        option '--rspec', 'Set up RSpec'
        option '--sourced', 'Use Sourced for durable, event-sourced storage'
        option '--sidereal-path <path>', "Use a local Sidereal checkout instead of GitHub's"
        option '--skip-bundle', "Don't run bundle install"
        option '--no-skills', "Don't install AI agent skills (bin/sid skills update)"
        option '--force', 'Write into an existing, non-empty directory'
      end

      def call
        return print_usage if @options[:help]
        raise Error, 'Name the new app, e.g. `sid new my_app`' unless @path

        app_name = File.basename(@path)
        unless NAME_FORMAT.match?(app_name)
          raise Error, "#{app_name.inspect} isn't a valid app name. Use lowercase letters, digits and underscores, starting with a letter."
        end

        root = File.expand_path(@path)
        if Dir.exist?(root) && !Dir.empty?(root) && !@options[:force]
          raise Error, "#{root} already exists and isn't empty. Use --force to write into it anyway."
        end

        context = Context.new(
          app_name:,
          title: app_name.split('_').map(&:capitalize).join(' '),
          sidereal_path: @options[:sidereal_path] && File.expand_path(@options[:sidereal_path]),
          rspec: !!@options[:rspec],
          sourced: !!@options[:sourced]
        )

        terminal.puts "Creating #{context.title} in #{root}", style: :title
        Generator.new(TEMPLATES, root, context).generate do |path|
          terminal.print_line :key, '  create  ', :reset, path
        end

        if @options[:skip_bundle]
          instructions(context, bundled: false)
          return
        end

        run!(root, 'bundle', 'install')
        if context.rspec?
          run!(root, 'bundle', 'exec', 'rspec', '--init')
          load_boot_in_spec_helper(root)
        end
        # The skills of Sidereal and the integrations the app requires.
        run!(root, 'bin/sid', 'skills', 'update') unless @options[:no_skills]

        instructions(context, bundled: true)
      end

      private

      # Run a command in the new app's directory, outside of any bundle the
      # `sid` process itself is running in.
      def run!(root, *command)
        terminal.puts
        terminal.print_line :key, '  run  ', :reset, command.join(' ')
        ok = with_unbundled_env { system(*command, chdir: root) }
        raise Error, "`#{command.join(' ')}` failed in #{root}" unless ok
      end

      def with_unbundled_env(&)
        defined?(Bundler) ? Bundler.with_unbundled_env(&) : yield
      end

      def load_boot_in_spec_helper(root)
        path = File.join(root, 'spec', 'spec_helper.rb')
        File.write(path, <<~RUBY + File.read(path))
          # Load the app (Zeitwerk, Sidereal's configuration) before every spec,
          # and build its components, so classes can read the ones they inject.
          # Building starts nothing: no pubsub, no workers.
          require_relative '../boot'
          Sidereal.config.build!

        RUBY
      end

      def instructions(context, bundled:)
        terminal.puts
        terminal.puts "#{context.title} is ready.", style: :title
        terminal.puts
        terminal.puts 'Start the server:'
        terminal.puts
        terminal.print_line :key, "  cd #{@path}"
        terminal.print_line :key, '  bundle install' unless bundled
        terminal.print_line :key, '  bundle exec rspec --init' if context.rspec? && !bundled
        terminal.print_line :key, '  bin/sid skills update' unless bundled || @options[:no_skills]
        terminal.print_line :key, '  bin/dev'
        terminal.puts
        terminal.puts "Then open http://localhost:#{context.port} in two windows and say hello."
        if context.rspec? && bundled
          terminal.puts
          terminal.puts 'Run the specs with:'
          terminal.puts
          terminal.print_line :key, '  bundle exec rspec'
        end
        if context.rspec? && !bundled
          terminal.puts
          terminal.puts "After `rspec --init`, add `require_relative '../boot'` to the top of spec/spec_helper.rb."
        end
      end
    end
  end
end
