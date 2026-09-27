# frozen_string_literal: true

require 'sidereal/skills'

module Sidereal
  module CLI
    # `sid skills`: keep the app's agent skills up to date. Only registered by
    # an app's bin/sid (see {CLI.load_app}).
    class SkillsCommand < Command
      # `sid skills update`
      class Update < Command
        self.description = "Write Sidereal's and its integrations' skills into the app's skills/ directory"

        def call
          # Loading the app requires its integrations, which register their skills.
          CLI.boot_app!(build: false)
          Sidereal.skills.install(CLI.app_root) do |action, path|
            case action
            when :write then terminal.print_line :key, '  write   ', :reset, path
            when :link then terminal.print_line :key, '  link    ', :reset, "#{path} -> #{Skills::LINKS[path]}"
            when :skip then terminal.print_line :key, '  skip    ', :reset, "#{path} (already exists)"
            end
          end
        end
      end

      self.description = "Manage the app's AI agent skills"

      nested :command, { 'update' => Update }

      def call
        if @command
          @command.call
        else
          print_usage
        end
      end
    end
  end
end
