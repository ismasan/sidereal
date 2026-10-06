# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'sidereal/cli'

module Sidereal
  module Integrations
    module Sourced
      # The `sid sourced` commands that need Sourced loaded, registered into
      # {Sidereal::CLI::Sourced} by {Sidereal::Integrations::Sourced.setup} —
      # so they exist for an app that configures the integration, beside the
      # `install` that sets it up in one that hasn't. This file defines the command classes and
      # nothing else — it doesn't load Sourced, which the commands do for
      # themselves through {Sidereal::CLI.boot_app!}.
      module CLI
        # The causality tree of a Sourced topology ({::Sourced::Topology.build}):
        # commands and the events they produce, the read models and automations
        # that consume those events, and the commands automations dispatch.
        class TopologyTree
          LABELS = {
            'command' => 'command',
            'event' => 'event',
            'automation' => 'automation',
            'readmodel' => 'read model'
          }.freeze

          # @param nodes [Array<#type, #id, #name, #group_id>] topology nodes.
          #   Commands, automations and read models also answer +produces+;
          #   automations and read models answer +consumes+; commands and
          #   events answer +schema+, their payload's JSON Schema.
          # @param schemas [Boolean] add a +schema+ line under each command
          #   and event, the first time it's shown
          def initialize(nodes, schemas: false)
            @nodes = nodes
            @schemas = schemas
            @by_id = nodes.to_h { |node| [node.id, node] }
          end

          # Each line of the tree, yielded as the node's label and its text,
          # with its tree prefix.
          #
          # @yieldparam prefix [String] tree drawing before the node
          # @yieldparam kind [String] command, event, automation, read model,
          #   or schema for a schema line
          # @yieldparam text [String]
          # @return [void]
          def each_line(&block)
            @shown = {}
            @block = block
            roots.each { |node| visit(node, '', '', root: true) }
          end

          # @return [Array<String>] the whole tree as plain text
          def lines
            result = []
            each_line { |prefix, kind, text| result << "#{prefix}#{kind} #{text}" }
            result
          end

          private

          def of_type(type) = @nodes.select { |node| node.type == type }

          # Entry points first: commands no automation dispatches. Then whatever
          # they don't reach: commands only reached through a cycle, events no
          # command produces, and the rest.
          def roots
            dispatched = of_type('automation').flat_map(&:produces)
            entry_points = of_type('command').reject { |command| dispatched.include?(command.id) }
            produced = of_type('command').flat_map(&:produces)
            external_events = of_type('event').reject { |event| produced.include?(event.id) }

            entry_points +
              of_type('command') +
              external_events +
              of_type('readmodel') +
              of_type('automation')
          end

          def visit(node, prefix, child_prefix, root: false)
            return if root && @shown.key?(node.id)

            if @shown.key?(node.id)
              @block.call(prefix, label(node), "#{describe(node)} (see above)")
              return
            end

            @shown[node.id] = true
            @block.call(prefix, label(node), describe(node))

            kids = children(node)
            if @schemas && (schema = schema_of(node))
              @block.call(child_prefix + (kids.any? ? '│  ' : '   '), 'schema', JSON.generate(schema))
            end
            kids.each_with_index do |child, index|
              last = index == kids.size - 1
              visit(child, child_prefix + (last ? '└─ ' : '├─ '), child_prefix + (last ? '   ' : '│  '))
            end
          end

          def children(node)
            case node.type
            when 'command'
              node.produces.map { |id| @by_id[id] || placeholder('event', id) }
            when 'event'
              consumers = of_type('readmodel') + of_type('automation')
              consumers.select { |consumer| consumer.consumes.include?(node.id) }
            when 'automation'
              node.produces.map { |id| @by_id[id] || placeholder('command', id) }
            when 'readmodel'
              node.produces.filter_map { |id| @by_id[id] }
            else
              []
            end
          end

          # A message a node refers to that has no node of its own.
          def placeholder(type, id)
            ::Struct.new(:type, :id, :name, :group_id, :produces, :consumes)
                    .new(type, id, nil, nil, [], [])
          end

          def label(node) = LABELS.fetch(node.type, node.type)

          def schema_of(node)
            schema = node.schema if node.respond_to?(:schema)
            schema unless schema.nil? || schema.empty?
          end

          def describe(node)
            case node.type
            when 'command', 'event'
              [node.id, node.name].compact.join('  ')
            when 'automation'
              "#{node.name}  in #{node.group_id}"
            when 'readmodel'
              node.name.to_s
            else
              node.id.to_s
            end
          end
        end

        # `sid sourced migration`
        #
        # Sourced renders the migration from its own template, so this needs
        # the gem loaded — which is why `sourced install` runs it in a separate
        # process, after bundling, rather than doing it inline.
        class Migration < Sidereal::CLI::Command
          self.description = "Write the migration for Sourced's tables into db/migrations"

          options do
            option '--force', 'Write another one even if the app already has it'
          end

          NAME = 'create_sourced_tables'

          def call
            Sidereal::CLI.boot_app!

            # Sourced's own writer neither creates the directory nor refuses to
            # overwrite, and a second copy of this migration would be a stray
            # file that does nothing.
            existing = Dir[File.join(directory, "*_#{NAME}.rb")].sort.last
            if existing && !@options[:force]
              terminal.print_line :key, '  skip    ', :reset, "#{relative(existing)} (already there)"
              return
            end

            FileUtils.mkdir_p(directory)
            # The app's own store, so a table prefix it configured is used.
            path = ::Sourced.store.copy_migration_to do
              File.join(directory, "#{Time.now.utc.strftime(Sidereal::CLI::DB::TIMESTAMP)}_#{NAME}.rb")
            end

            terminal.print_line :key, '  create  ', :reset, relative(path)
            terminal.puts
            terminal.puts 'Apply it with:'
            terminal.puts
            terminal.print_line :key, '  bin/sid db migrations run'
          end

          private

          def directory = File.join(Sidereal::CLI.app_root, Sidereal::CLI::DB::MIGRATIONS_DIR)

          def relative(path) = path.delete_prefix("#{Sidereal::CLI.app_root}/")
        end

        # `sid sourced groups`
        class Groups < Sidereal::CLI::Command
          # `sid sourced groups list`
          #
          # A consumer group per reactor, with how far it has read and how far
          # behind the store it is. Groups are registered when the app starts,
          # not when it is built, so a store whose app has never run has none.
          class List < Sidereal::CLI::Command
            self.description = 'List the consumer groups, with their status, partitions and position'

            # Retry at is dropped when no group is waiting to retry.
            HEADERS = ['Group', 'Status', 'Partitions', 'Position', 'Lag', 'Retry at'].freeze
            ALWAYS = 5

            def call
              Sidereal::CLI.boot_app!
              stats = Sidereal.config['sourced.store'].stats
              if stats.groups.empty?
                terminal.puts 'No consumer groups yet. They are registered when the app starts.'
                return
              end

              count = stats.groups.size
              terminal.print_line :title, "#{count} #{count == 1 ? 'group' : 'groups'}", :reset,
                                  ", store at position #{stats.max_position}"
              terminal.puts
              Sidereal::CLI::Commands.print_table(terminal, HEADERS, rows(stats), keep: ALWAYS)
              print_notes(stats)
            end

            private

            def rows(stats)
              stats.groups.map do |group|
                [
                  group[:group_id].to_s,
                  group[:status].to_s,
                  group[:partition_count].to_s,
                  group[:newest_processed].to_s,
                  (stats.max_position - group[:newest_processed]).to_s,
                  group[:retry_at]&.strftime('%Y-%m-%d %H:%M:%S').to_s
                ]
              end
            end

            # What the table can't carry: why a group isn't running. That is an
            # exception when it failed, and the operator's own words when
            # someone stopped it — `groups stop --message` keeps them here.
            def print_notes(stats)
              noted = stats.groups.reject { |group| group[:error_context].empty? }
              return if noted.empty?

              terminal.puts
              noted.each do |group|
                style = group[:status].to_s == 'failed' ? :error : :key
                terminal.print_line style, "#{group[:group_id]}: ", :reset, note(group[:error_context])
              end
            end

            def note(context)
              exception = [context[:exception_class], context[:exception_message]].compact.join(': ')
              return exception unless exception.empty?
              return context[:message].to_s if context[:message]

              # Never a blank line: say whatever is there.
              context.inspect
            end
          end

          # `sid sourced groups stop <group>`
          #
          # A stopped group is skipped when work is claimed, so its reactor
          # stops consuming while the rest of the app carries on.
          class Stop < Sidereal::CLI::Command
            self.description = 'Stop a consumer group, so its reactor claims no more work'

            # Not `name`: Samovar::Command#name is the command's own name, so
            # `one :name` would always be set, to "stop".
            one :group_name, 'The group to stop, as `groups list` shows it'

            options do
              option '--message <text>', 'Why it was stopped, kept with the group'
            end

            def call
              unless @group_name
                # Fully qualified: a bare Error here resolves out to
                # Sidereal::Error, which Application.call doesn't rescue — the
                # message would reach the user as a backtrace.
                raise Sidereal::CLI::Error, 'Name a group, e.g. `bin/sid sourced groups stop Todos`. ' \
                                            '`bin/sid sourced groups list` shows them.'
              end

              Sidereal::CLI.boot_app!
              store = Sidereal.config['sourced.store']
              group = store.stats.groups.find { |candidate| candidate[:group_id].to_s == @group_name }
              return terminal.puts("#{@group_name} is already stopped.") if group&.fetch(:status).to_s == 'stopped'

              # The store knows which groups exist, and says so for a name it
              # doesn't recognise — this only has to keep that out of a backtrace.
              begin
                store.stop_consumer_group(@group_name, @options[:message])
              rescue ::Sourced::Store::UnknownConsumerGroupError => e
                raise Sidereal::CLI::Error, e.message
              end

              terminal.print_line :key, '  stopped  ', :reset, @group_name
              terminal.puts
              terminal.puts 'It claims no more work. Start it again from `bin/sid console`: ' \
                            "Sidereal.config['sourced.store'].start_consumer_group(#{@group_name.inspect})"
            end
          end

          self.description = "Inspect the app's consumer groups"

          nested :command, { 'list' => List, 'stop' => Stop }

          def call
            @command ? @command.call : print_usage
          end
        end

        # `sid sourced topology`
        class Topology < Sidereal::CLI::Command
          self.description = 'Print how commands, events, read models and automations connect'

          options do
            option '--schemas', "Add a line under each command and event with its payload's JSON Schema"
          end

          STYLES = {
            'command' => :key,
            'event' => :event,
            'automation' => :automation,
            'read model' => :read_model,
            'schema' => :schema
          }.freeze

          def call
            Sidereal::CLI.boot_app!

            nodes = ::Sourced.topology
            if nodes.empty?
              terminal.puts 'No Sourced deciders, projectors or reactors are registered.'
              return
            end

            terminal[:event] = terminal.style(:yellow)
            terminal[:automation] = terminal.style(:magenta)
            terminal[:read_model] = terminal.style(:green)
            terminal[:schema] = terminal.style(nil, nil, :faint)

            first = true
            TopologyTree.new(nodes, schemas: !!@options[:schemas]).each_line do |prefix, kind, text|
              # A blank line between trees.
              terminal.puts if prefix.empty? && !first
              first = false
              terminal.print_line prefix, STYLES.fetch(kind, :reset), kind, :reset, " #{text}"
            end
          end
        end
      end
    end
  end
end
