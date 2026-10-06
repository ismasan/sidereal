# frozen_string_literal: true

require 'fileutils'
require_relative 'generator'

module Sidereal
  module CLI
    # Writes into an app that already exists — what an `install` command does:
    # `sid db install` today, and whatever an integration adds next. {New}
    # creates an app from nothing and uses only {#run!}.
    #
    # Every method is idempotent, and returns what it did as +[action, path]+
    # pairs for the command to render: +:create+, +:update+ or +:skip+. So an
    # install can be run twice and will say that there was nothing to do.
    # {Sidereal::Skills#install} reports the same way.
    class Installer
      # @param root [String] the app's root directory
      def initialize(root)
        @root = root
      end

      # Add gems to the app's Gemfile, unless it already asks for them. Any
      # options become the rest of the `gem` line, so a gem can come from
      # wherever Bundler understands:
      #
      #   installer.gems('sequel', 'sqlite3')
      #   installer.gems('sourced', github: 'ismasan/sourced', branch: 'ccc')
      #
      # Appended at the end rather than inserted into a group: a Gemfile is
      # Ruby, so a trailing `gem` line is valid wherever the groups are, and
      # guessing at the structure of a file the author owns is not worth it.
      #
      # `bundle add` would write the line instead, but it exits non-zero on a
      # gem that is already there, needs the network to resolve a version, and
      # writes the lock file even with --skip-install — so it could not be run
      # twice, and an install's --skip-bundle would not mean what it says.
      #
      # @param names [Array<String>]
      # @param comment [String, nil] a comment line above them, when any are added
      # @param options [Hash] the rest of the `gem` line
      # @return [Array<Array>] one pair, for the Gemfile
      def gems(*names, comment: nil, **options)
        path = File.join(@root, 'Gemfile')
        raise Error, "No Gemfile in #{@root}. Is this a Sidereal app?" unless File.file?(path)

        missing = names - gemfile_dependencies(path)
        return [[:skip, 'Gemfile']] if missing.empty?

        added = missing.map { |name| gem_line(name, options) }.join
        added = "#{comment}\n#{added}" if comment
        File.write(path, "#{File.read(path).rstrip}\n\n#{added}")
        [[:update, 'Gemfile']]
      end

      # Add lines to the app's .gitignore, skipping any that are already there
      # word for word, and creating the file if the app hasn't got one.
      #
      # @param lines [Array<String>]
      # @return [Array<Array>] one pair, for the .gitignore
      def ignore(*lines)
        path = File.join(@root, '.gitignore')
        content = File.exist?(path) ? File.read(path) : nil
        present = content.to_s.lines.map(&:strip)
        missing = lines.reject { |line| present.include?(line.strip) }
        return [[:skip, '.gitignore']] if missing.empty?

        body = content.nil? || content.strip.empty? ? '' : "#{content.rstrip}\n"
        File.write(path, "#{body}#{missing.join("\n")}\n")
        [[content.nil? ? :create : :update, '.gitignore']]
      end

      # Write a template directory into the app. Keeps a file that is already
      # there unless +overwrite+ — the one the author has edited is the one
      # worth keeping.
      #
      # @param source [String] a template directory, see {Generator}
      # @param context [Object] what the ERB templates are evaluated against
      # @param overwrite [Boolean]
      # @return [Array<Array>] a pair per template
      def templates(source, context, overwrite: false)
        actions = []
        Generator.new(source, @root, context).generate(overwrite:) do |action, path|
          actions << [action, path]
        end
        actions
      end

      # Run a command in the app, outside whatever bundle this process is
      # running in — gems just added to the Gemfile aren't in the lock file
      # yet, so resolving needs a clean environment.
      #
      # @param command [Array<String>]
      # @return [true]
      # @raise [Error] if the command fails
      def run!(*command)
        ok = with_unbundled_env { system(*command, chdir: @root) }
        raise Error, "`#{command.join(' ')}` failed in #{@root}" unless ok

        true
      end

      private

      def gem_line(name, options)
        parts = ["gem '#{name}'"]
        options.each { |key, value| parts << "#{key}: #{value.is_a?(::String) ? "'#{value}'" : value.inspect}" }
        "#{parts.join(', ')}\n"
      end

      # The gems the Gemfile asks for, as Bundler itself reads them — it is the
      # one thing that knows the format. Scanning the text for `gem 'name'`
      # misses the other ways of writing it, such as a `gem("sqlite3")` inside
      # a group, which would then be added a second time. Parsing needs no
      # network and writes nothing.
      #
      # ScriptError as well as StandardError: a Gemfile is Ruby, and a
      # `require` in one can fail with a LoadError.
      #
      # @return [Array<String>]
      def gemfile_dependencies(path)
        require 'bundler'
        dsl = ::Bundler::Dsl.new
        dsl.eval_gemfile(path)
        dsl.dependencies.map(&:name)
      rescue ::ScriptError, ::StandardError => e
        raise Error, "Couldn't read #{path}: #{e.message}"
      end

      def with_unbundled_env(&)
        defined?(::Bundler) ? ::Bundler.with_unbundled_env(&) : yield
      end
    end
  end
end
