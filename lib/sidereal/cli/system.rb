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

        def truncate(text, width = TYPE_WIDTH)
          text.length > width ? "#{text[0, width - 1]}…" : text
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
          print_table(graph)
          print_missing(graph)
          print_problem(problem)
        end

        private

        GUTTER = '  '
        # Enough for a key or two even on a narrow terminal.
        MIN_EDGE_WIDTH = 20
        # Below this a type name says nothing, so stop giving its room away.
        MIN_TYPE_WIDTH = 16

        # Aligned columns under a bold header, with the edges wrapped into the
        # last one rather than trailing off the line or spilling onto an
        # indented one of their own. Not {Commands.print_table}, which the other
        # listings share: it can't wrap, and widening it for one caller seemed
        # worse than keeping the wrapping here.
        def print_table(graph)
          headers = ['Component', 'Type', 'State', @options[:dependents] ? 'Used by' : 'Needs']
          rows = graph.components.map { |node| row_for(node) }
          widths = (0..2).map { |i| [headers[i].length, *rows.map { |row| row[i].first.length }].max }
          widths[1], edge_width = share_width(widths)
          rows.each { |row| row[1][0] = truncate(row[1].first, widths[1]) }

          terminal.print_line(:title, header_line(headers, widths))
          rows.each { |row| print_row(row, widths, edge_width) }
        end

        # A key names the component, so it is never shortened; the type gives
        # up room instead, down to a floor, so the edges keep a column to wrap
        # into on a narrower terminal.
        #
        # @return [Array(Integer, Integer)] the type and edge widths
        def share_width(widths)
          fixed = widths[0] + widths[2] + (GUTTER.length * 3) + 1
          spare = terminal.width - fixed - widths[1]
          return [widths[1], spare] if spare >= MIN_EDGE_WIDTH

          type = [widths[1] + spare - MIN_EDGE_WIDTH, MIN_TYPE_WIDTH].max
          [type, [terminal.width - fixed - type, MIN_EDGE_WIDTH].max]
        end

        def header_line(headers, widths)
          (headers.take(3).each_with_index.map { |text, i| text.ljust(widths[i]) } + [headers.last]).join(GUTTER)
        end

        def row_for(node)
          [
            [node[:key], status_style(node[:implemented], node[:status])],
            [truncate(node[:type_name]), :type],
            [state_of(node), state_style(node)],
            @options[:dependents] ? node[:dependents] : node[:deps],
            node[:missing] || []
          ]
        end

        # One cell rather than a column each: the extra words are rare, and a
        # column per flag would be mostly empty.
        def state_of(node)
          return 'not implemented' unless node[:implemented]

          parts = [node[:status].to_s]
          parts << node[:mode].to_s if node[:mode] && node[:mode] != :singleton
          parts << 'deferred' if node[:deferred]
          parts.join(', ')
        end

        def state_style(node)
          return :bad unless node[:implemented]
          return :flag if node[:deferred]

          :muted
        end

        def print_row(row, widths, edge_width)
          keys, missing = row[3], row[4]
          lines = wrap(keys, edge_width)
          # The last column is only padded when something follows it, so a row
          # without edges doesn't end in a run of spaces.
          cells = (0..2).flat_map do |i|
            last = i == 2 && lines.empty?
            [row[i].last, last ? row[i].first : row[i].first.ljust(widths[i]), :reset, last ? '' : GUTTER]
          end

          terminal.print_line(*cells, *edge_cells(lines.first || [], missing))
          indent = ' ' * (widths.sum + (GUTTER.length * 3))
          lines.drop(1).each { |line| terminal.print_line(:reset, indent, *edge_cells(line, missing)) }
        end

        def edge_cells(keys, missing)
          keys.flat_map.with_index do |key, i|
            [missing.include?(key) ? :bad : :reset, i.zero? ? key : ", #{key}"]
          end
        end

        # Greedy wrap of the key list, so a long one reads down the column
        # instead of off the edge of the terminal.
        def wrap(keys, width)
          keys.each_with_object([]) do |key, lines|
            piece = lines.last && !lines.last.empty? ? ", #{key}" : key
            if lines.empty? || lines.last.sum { |k| k.length + 2 } - 2 + piece.length > width
              lines << [key]
            else
              lines.last << key
            end
          end
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
