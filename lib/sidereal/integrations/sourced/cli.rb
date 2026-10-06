# frozen_string_literal: true

require 'json'
require 'sidereal/cli'

module Sidereal
  module Integrations
    module Sourced
      # `sid sourced`: commands for apps that use Sourced. Registered by
      # {Sidereal::Integrations::Sourced.setup}, so they exist for an app that
      # configures the integration. This file defines the command classes and
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

        # `sid sourced`
        class Namespace < Sidereal::CLI::Command
          self.description = "Inspect the app's Sourced setup"

          nested :command, { 'topology' => Topology }

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
  end
end
