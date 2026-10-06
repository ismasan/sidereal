# frozen_string_literal: true

# For ComponentError, which this rescues to describe a broken configuration
# rather than fail on it. A hard dependency of the gem, so always available.
require 'sourced/component'

module Sidereal
  module CLI
    # `sid system`: what the app is made of — its components and how they fit
    # together. A built-in, like {DB}: it describes whatever the app configured,
    # so it needs no integration to register it.
    class System < Command
      # `sid system graph`
      #
      # The components in dependency order — the order they are built and
      # started in — each with what it depends on. A component tree is a DAG,
      # not a tree, so this lists edges per component rather than nesting them:
      # a component with two dependents would otherwise have to appear twice.
      class Graph < Command
        self.description = 'Print the app components and how they depend on each other'

        options do
          option '--dependents', 'Show what depends on each component, rather than what it depends on'
          option '--mermaid', 'Print a Mermaid flowchart of the graph, and nothing else'
        end

        # Long enough for the interface types Sidereal declares, short enough to
        # leave room for the key beside it.
        TYPE_WIDTH = 44

        STATUS_STYLES = {
          started: :ok, built: :ok, prepared: :pending, open: :muted,
          stopped: :muted, torn_down: :muted, failed: :bad
        }.freeze

        def call
          # A configuration that won't build is exactly when this command is
          # wanted, so a component error is reported under the graph rather
          # than instead of it. Everything else — no app, an app that failed to
          # load — still stops us.
          problem = begin
            CLI.boot_app!
            nil
          rescue ::Sourced::Component::ComponentError => e
            e
          end

          graph = Sidereal.config.graph
          return print_mermaid(graph, problem) if @options[:mermaid]

          define_styles!
          print_header(graph)
          # Both columns size to the data, so a small app doesn't get a wide,
          # mostly-blank table.
          keys = column_width(graph) { |node| node[:key] }
          types = column_width(graph) { |node| truncate(node[:type_name]) }
          graph.components.each { |node| print_component(node, keys, types) }
          print_footer(graph, problem)
        end

        private

        # The diagram alone, so `bin/sid system graph --mermaid > graph.mmd`
        # writes a file that needs no editing — no header, no colour, no
        # trailing notes. A configuration problem goes to stderr instead, which
        # a redirect leaves alone.
        def print_mermaid(graph, problem)
          warn("#{problem.class.name.split('::').last}: #{problem.message}") if problem
          output.puts(graph.to_mermaid)
        end

        def define_styles!
          terminal[:muted] = terminal.style(nil, nil, :faint)
          terminal[:ok] = terminal.style(:green)
          terminal[:pending] = terminal.style(:yellow)
          terminal[:bad] = terminal.style(:red, nil, :bold)
          terminal[:flag] = terminal.style(:magenta)
          terminal[:mode] = terminal.style(:yellow)
        end

        def print_header(graph)
          terminal.print_line :title, 'Sidereal.config', :reset, "  #{graph.components.size} components, ",
                              STATUS_STYLES.fetch(graph.status, :reset), graph.status.to_s
          terminal.puts
        end

        def print_component(node, keys, types)
          flags = flags(node)
          type = truncate(node[:type_name])
          # Only pad when something follows, so a row without flags doesn't end
          # in a run of spaces.
          type = type.ljust(types) if flags.any?
          terminal.print_line(status_style(node), node[:key].ljust(keys), :muted, "  #{type}", *flags)
          print_edges(node)
        end

        # The widest value in a column, so it sizes to the data.
        def column_width(graph)
          graph.components.map { |node| yield(node).length }.max.to_i
        end

        # Unimplemented is the one that stops a boot, so it is the one that
        # shouts. The rest are shape, not trouble.
        def flags(node)
          parts = []
          parts += [:bad, ' unimplemented'] unless node[:implemented]
          parts += [:mode, " #{node[:mode]}"] if node[:mode] && node[:mode] != :singleton
          parts += [:flag, ' deferred'] if node[:deferred]
          parts
        end

        def print_edges(node)
          keys = @options[:dependents] ? node[:dependents] : node[:deps]
          return if keys.empty?

          label = @options[:dependents] ? 'used by' : 'needs  '
          missing = node[:missing] || []
          terminal.print_line :muted, "  #{label}  ", *keys.flat_map.with_index { |key, i|
            [missing.include?(key) ? :bad : :muted, i.zero? ? key : ", #{key}"]
          }
        end

        def print_footer(graph, problem)
          missing = graph.components.flat_map { |node| node[:missing] }.uniq
          unless missing.empty?
            terminal.puts
            terminal.print_line :bad, 'Not declared: ', :reset, missing.join(', ')
          end

          return unless problem

          terminal.puts
          terminal.print_line :bad, "#{problem.class.name.split('::').last}: ", :reset, problem.message
        end

        def status_style(node)
          return :bad unless node[:implemented]

          STATUS_STYLES.fetch(node[:status], :reset)
        end

        def truncate(text)
          text.length > TYPE_WIDTH ? "#{text[0, TYPE_WIDTH - 1]}…" : text
        end
      end

      # The commands under `sid system`, by the name they're typed as — the same
      # hash {System} dispatches on, so one registered later is still found.
      COMMANDS = { 'graph' => Graph }

      # Add a command to `sid system`.
      #
      # @param name [String]
      # @param command_class [Class<Command>]
      # @return [Class<Command>] command_class
      def self.register(name, command_class)
        COMMANDS[name] = command_class
      end

      self.description = 'Inspect what the app is made of'

      nested :command, COMMANDS

      def call
        @command ? @command.call : print_usage
      end
    end
  end
end
