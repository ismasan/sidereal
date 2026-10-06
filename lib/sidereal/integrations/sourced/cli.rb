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
          # What `start` and `stop` both need. Each keeps its own readable
          # `call` — this is only the plumbing they share.
          module Action
            # Not `name`: Samovar::Command#name is the command's own name, so
            # `one :name` would always be set, to "stop" or "start".
            def group_named!(verb)
              return @group_name if @group_name

              # Fully qualified: a bare Error here resolves out to
              # Sidereal::Error, which Application.call doesn't rescue — the
              # message would reach the user as a backtrace.
              raise Sidereal::CLI::Error, "Name a group, e.g. `bin/sid sourced groups #{verb} Todos`. " \
                                          '`bin/sid sourced groups list` shows them.'
            end

            # The lifecycle goes through the router, not the store: it resolves
            # the reactor, and calls its on_stop/on_start/on_reset afterwards,
            # which the store knows nothing about.
            def router = Sidereal.config['sourced.router']

            # Only for stats — the router doesn't keep any.
            def store = Sidereal.config['sourced.store']

            def status_of(name)
              store.stats.groups.find { |group| group[:group_id].to_s == name }&.fetch(:status).to_s
            end

            # Two ways to be unknown, and both name what is known: the router
            # has no such reactor, or it has one the store has never seen
            # because the app hasn't run. This only keeps them out of a backtrace.
            def on_known_group
              yield
            rescue ::Sourced::Router::UnregisteredReactorError, ::Sourced::Store::UnknownConsumerGroupError => e
              raise Sidereal::CLI::Error, e.message
            end
          end

          # `sid sourced groups stop <group>`
          #
          # A stopped group is skipped when work is claimed, so its reactor
          # stops consuming while the rest of the app carries on.
          class Stop < Sidereal::CLI::Command
            include Action

            self.description = 'Stop a consumer group, so its reactor claims no more work'

            one :group_name, 'The group to stop, as `groups list` shows it'

            options do
              option '--message <text>', 'Why it was stopped, kept with the group'
            end

            def call
              name = group_named!('stop')
              Sidereal::CLI.boot_app!
              return terminal.puts("#{name} is already stopped.") if status_of(name) == 'stopped'

              on_known_group { router.stop_consumer_group(name, @options[:message]) }

              terminal.print_line :key, '  stopped  ', :reset, name
              terminal.puts
              terminal.puts "It claims no more work until `bin/sid sourced groups start #{name}`. " \
                            'Messages keep arriving in the store meanwhile.'
            end
          end

          # `sid sourced groups start <group>`
          #
          # Puts a stopped or failed group back to work, from where it left
          # off. Starting a failed one clears the error that stopped it.
          class Start < Sidereal::CLI::Command
            include Action

            self.description = 'Start a stopped or failed consumer group again'

            one :group_name, 'The group to start, as `groups list` shows it'

            def call
              name = group_named!('start')
              Sidereal::CLI.boot_app!
              return terminal.puts("#{name} is already running.") if status_of(name) == 'active'

              on_known_group { router.start_consumer_group(name) }

              terminal.print_line :key, '  started  ', :reset, name
              terminal.puts
              terminal.puts 'It claims work again, from where it left off, and anything that arrived ' \
                            'while it was stopped. A failed group has its error cleared.'
            end
          end

          # `sid sourced groups reset <group>`
          #
          # Drops the group's offsets so its reactor reads the whole store
          # again — rebuilding whatever it derives. Nothing is lost, since the
          # messages are still there, but the work is redone, so it asks first.
          class Reset < Sidereal::CLI::Command
            include Action

            self.description = 'Reset a consumer group, so its reactor processes everything again'

            one :group_name, 'The group to reset, as `groups list` shows it'

            options do
              option '--yes', "Don't ask for confirmation"
            end

            def call
              name = group_named!('reset')
              Sidereal::CLI.boot_app!
              refuse_exclusive(name)
              return terminal.puts('Not reset.') unless confirmed?(name)

              on_known_group { router.reset_consumer_group(name) }

              terminal.print_line :key, '  reset  ', :reset, name
              terminal.puts
              terminal.puts 'It reads the store from the beginning next time the app runs.'
            end

            private

            # Sourced skips a reset for an exclusive group, but that guard lives
            # in the store and reads the groups registered in *its* process —
            # filled when the app starts, not when the CLI builds it, so it
            # never fires here even through the router. Ask the reactor instead,
            # or the offsets would go and only orphan its partitions.
            def refuse_exclusive(name)
              reactor = router.reactors.find { |candidate| candidate.group_id.to_s == name }
              return unless reactor.respond_to?(:exclusive?) && reactor.exclusive?

              raise Sidereal::CLI::Error,
                    "#{name} handles its messages exclusively and deletes them as it acks them, so there " \
                    'is nothing to replay. Resetting it would only orphan the partitions it holds.'
            end

            def confirmed?(name)
              return true if @options[:yes]

              unless $stdin.tty?
                raise Sidereal::CLI::Error,
                      "Resetting #{name} makes its reactor redo every message. Pass --yes to confirm."
              end

              terminal.puts "#{name} will read the whole store again, rebuilding whatever it derives."
              output.print 'Reset it? [y/N] '
              output.flush
              $stdin.gets.to_s.strip.casecmp?('y')
            end
          end

          self.description = "Inspect the app's consumer groups"

          nested :command, { 'list' => List, 'reset' => Reset, 'start' => Start, 'stop' => Stop }

          def call
            @command ? @command.call : print_usage
          end
        end

        # `sid sourced messages`
        class Messages < Sidereal::CLI::Command
          # `sid sourced messages list [--tail]`
          #
          # The log, one message per line. Only the messages go to stdout —
          # everything else is stderr — so `| grep` and `> file` get just the
          # log, in either mode.
          class List < Sidereal::CLI::Command
            self.description = 'List the most recent messages in the store'

            options do
              option '--limit <n>', 'How many to show (default 100)', type: Integer, default: 100
              option '--tail', 'Keep printing messages as they arrive'
            end

            INTERVAL = 1
            MIN_TYPE_WIDTH = 24

            def call
              # Guards the tail loop as much as the listing: a limit of zero
              # makes every batch both empty and "full", and it would spin.
              raise Sidereal::CLI::Error, '--limit must be at least 1' if @options[:limit] < 1

              Sidereal::CLI.boot_app!
              store = Sidereal.config['sourced.store']

              # Newest first, then reversed: read_all reads forward from the
              # start, so asking for a limit without :desc gives the oldest.
              recent = store.read_all(limit: @options[:limit], order: :desc).to_a.reverse
              @width = [recent.map { |message| message.type.length }.max.to_i, MIN_TYPE_WIDTH].max
              recent.each { |message| print_message(message) }
              output.flush

              tail(store, recent.last) if @options[:tail]
            end

            private

            # From the last message printed, not the result's last_position:
            # that is the store's own maximum, which runs ahead of the page
            # whenever the limit truncated it, and the difference would be
            # messages never shown.
            def tail(store, last)
              cursor = last ? last.position + 1 : 1
              warn "Tailing from position #{cursor}. Ctrl-C to stop."

              loop do
                messages = store.read_all(from_position: cursor, limit: @options[:limit]).to_a
                unless messages.empty?
                  messages.each { |message| print_message(message) }
                  output.flush
                  cursor = messages.last.position + 1
                end

                # A full batch is one the limit truncated, so there is already
                # more behind it: go straight back for it rather than
                # trickling a page a second until the backlog clears.
                sleep INTERVAL if messages.size < @options[:limit]
              end
            rescue Interrupt
              # Ctrl-C out of a tail is how it ends, not a crash.
              nil
            end

            def print_message(message)
              output.puts [
                message.position.to_s.rjust(6),
                # Whole, never shortened: an id is for grepping and for
                # pasting into the next command, and half of one is neither.
                message.id,
                message.created_at.strftime('%Y-%m-%d %H:%M:%S'),
                message.type.ljust(@width),
                payload_of(message)
              ].join('  ')
            end

            def payload_of(message)
              payload = message.payload
              return '' unless payload.respond_to?(:to_h)

              JSON.generate(payload.to_h)
            end
          end

          self.description = "Inspect the messages in the app's store"

          nested :command, { 'list' => List }

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
