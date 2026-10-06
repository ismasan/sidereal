# frozen_string_literal: true

# For ComponentError, which these rescue to describe a broken configuration
# rather than fail on it. A hard dependency of the gem, so always available.
require 'sourced/component'

module Sidereal
  module CLI
    # `sid system`: what the app is made of — its components and how they fit
    # together. A built-in, like {DB}: it describes whatever the app configured,
    # so it needs no integration to register it.
    class System < Command
      # What both views share: the styles, and how a component's state reads.
      module Rendering
        # Long enough for the interface types Sidereal declares, short enough to
        # leave room for the key beside it.
        TYPE_WIDTH = 44

        # A name is high-contrast whatever its state — the state itself is spelled
        # out beside it. Only trouble changes the colour.
        STATUS_STYLES = {
          started: :name, built: :name, prepared: :pending, open: :name,
          stopped: :name, torn_down: :name, failed: :bad
        }.freeze

        # Loading the app is what lets these describe it, and a configuration
        # that won't build is exactly when they are wanted — so a component
        # error comes back to be reported alongside the output rather than
        # instead of it. Everything else — no app, an app that failed to load —
        # still stops the command.
        #
        # @return [Sourced::Component::ComponentError, nil]
        def boot_app_reporting_problems!
          CLI.boot_app!
          nil
        rescue ::Sourced::Component::ComponentError => e
          e
        end

        # Names at full contrast, types in green, and only the detail dimmed:
        # the dim state in brackets, and the purple labels.
        def define_styles!
          terminal[:name] = styled(nil, nil, :bold)             # component and namespace names
          terminal[:type] = styled(:green)                      # type names
          terminal[:muted] = styled(nil, nil, :faint)           # drawing, state, labels
          terminal[:flag] = styled(:magenta, nil, :faint)       # [mounted], deferred
          terminal[:mode] = styled(:yellow)                     # implemented by
          terminal[:pending] = styled(:yellow, nil, :bold)
          terminal[:bad] = styled(:red, nil, :bold)
        end

        # Console writes each style straight out with no reset between them, so
        # SGR attributes accumulate along a line: a faint tree prefix would dim
        # everything after it, whatever colour came next. Every style therefore
        # resets first. Both halves are nil on a terminal without colour, so
        # piped output stays plain.
        def styled(...)
          code = terminal.style(...)
          code && "#{terminal.reset}#{code}"
        end

        def status_style(implemented, status)
          return :bad unless implemented

          STATUS_STYLES.fetch(status, :reset)
        end

        def truncate(text)
          text.length > TYPE_WIDTH ? "#{text[0, TYPE_WIDTH - 1]}…" : text
        end

        def print_title(count, status)
          terminal.print_line :title, 'Sidereal.config', :reset, "  #{count} components, ",
                              STATUS_STYLES.fetch(status, :reset), status.to_s
          terminal.puts
        end

        def print_problem(problem)
          return unless problem

          terminal.puts
          terminal.print_line :bad, "#{problem_name(problem)}: ", :reset, problem.message
        end

        # The diagram alone, so `--mermaid > diagram.mmd` writes a file that
        # needs no editing — no header, no colour, no trailing notes. A
        # configuration problem goes to stderr instead, which a redirect leaves
        # alone.
        def print_mermaid(diagram, problem)
          warn("#{problem_name(problem)}: #{problem.message}") if problem
          output.puts(diagram.to_mermaid)
        end

        def problem_name(problem) = problem.class.name.split('::').last
      end

      # `sid system graph`
      #
      # The components in dependency order — the order they are built and
      # started in — each with what it depends on. Dependencies form a DAG, not
      # a tree, so this lists edges per component rather than nesting them: a
      # component with two dependents would otherwise have to appear twice.
      # For the nesting, see {Tree}.
      class Graph < Command
        include Rendering

        self.description = 'Print the app components and how they depend on each other'

        options do
          option '--dependents', 'Show what depends on each component, rather than what it depends on'
          option '--mermaid', 'Print a Mermaid flowchart of the graph, and nothing else'
        end

        def call
          problem = boot_app_reporting_problems!
          graph = Sidereal.config.graph
          return print_mermaid(graph, problem) if @options[:mermaid]

          define_styles!
          print_title(graph.components.size, graph.status)
          # Both columns size to the data, so a small app doesn't get a wide,
          # mostly-blank table.
          keys = column_width(graph) { |node| node[:key] }
          types = column_width(graph) { |node| truncate(node[:type_name]) }
          graph.components.each { |node| print_component(node, keys, types) }
          print_missing(graph)
          print_problem(problem)
        end

        private

        def print_component(node, keys, types)
          flags = flags(node)
          type = truncate(node[:type_name])
          # Only pad when something follows, so a row without flags doesn't end
          # in a run of spaces.
          type = type.ljust(types) if flags.any?
          terminal.print_line(
            status_style(node[:implemented], node[:status]), node[:key].ljust(keys),
            :type, "  #{type}", *flags
          )
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
            [missing.include?(key) ? :bad : :reset, i.zero? ? key : ", #{key}"]
          }
        end

        def print_missing(graph)
          missing = graph.components.flat_map { |node| node[:missing] }.uniq
          return if missing.empty?

          terminal.puts
          terminal.print_line :bad, 'Not declared: ', :reset, missing.join(', ')
        end
      end

      # `sid system tree`
      #
      # How the components nest, rather than how they depend on each other:
      # which are mounted (a library's own tree, such as Sourced's under
      # +sourced+), and which the app implemented over the library that declared
      # them. For the dependencies, see {Graph}.
      class Tree < Command
        include Rendering

        self.description = 'Print the app components as a tree, and who implemented each'

        options do
          option '--mermaid', 'Print a Mermaid flowchart of the tree, and nothing else'
        end

        def call
          problem = boot_app_reporting_problems!
          tree = Sidereal.config.tree
          return print_mermaid(tree, problem) if @options[:mermaid]

          define_styles!
          print_title(count(tree.root), tree.status)
          print_node(tree.root, tree.root.path || '(root)', '')
          print_children(tree.root.children, '')
          print_problem(problem)
        end

        private

        # Namespaces are structure, not components — they have no type and
        # nothing to build.
        def count(node)
          (node.namespace ? 0 : 1) + node.children.sum { |child| count(child) }
        end

        def print_children(nodes, prefix)
          nodes.each_with_index do |node, i|
            last = i == nodes.size - 1
            print_node(node, node.key, "#{prefix}#{last ? '└── ' : '├── '}")
            print_children(node.children, prefix + (last ? '    ' : '│   '))
          end
        end

        def print_node(node, name, prefix)
          parts = [:muted, prefix, name_style(node), name]
          parts += [:flag, ' [mounted]'] if node.mounted
          parts += [:type, " #{truncate(node.type_name)}", *state(node)] unless node.namespace
          # The interesting case: an app implementing a component a library
          # declared, such as `sourced.db` over the app's own connection.
          parts += [:mode, " implemented by #{node.implementer || '(root)'}"] if node.overridden?
          terminal.print_line(*parts)
        end

        # A namespace has no implementation to judge, so it isn't painted as a
        # failure — the mounted ones are the headings of the tree.
        def name_style(node)
          return node.mounted ? :title : :reset if node.namespace

          status_style(node.implemented, node.status)
        end

        def state(node)
          parts = [:muted, " (#{node.implemented ? node.mode : 'not implemented'}, #{node.status}"]
          parts += [:flag, ', deferred'] if node.deferred
          parts + [:muted, ')']
        end
      end

      # The commands under `sid system`, by the name they're typed as — the same
      # hash {System} dispatches on, so one registered later is still found.
      COMMANDS = { 'graph' => Graph, 'tree' => Tree }

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
