# frozen_string_literal: true

module UI
  module CrossPost
    # Reading the cross-post machines' definitions (Machine.to_h) for the
    # pages that draw them: their states, the commands each takes, and the
    # machine tree.
    module Charts
      extend self

      # A state: its path, the commands it takes itself, those it takes from
      # the states enclosing it, and its timers.
      Row = Data.define(:path, :type, :own, :inherited, :timers) do
        def accepted = own + inherited
      end

      # slug => machine, the root first.
      def machines = ::CrossPost.machines.to_h { [slug(it), it] }
      def machine(slug) = machines[slug]

      def slug(machine) = machine.name.delete_prefix('CrossPost::').gsub('::', '-').downcase
      def short_name(machine) = machine.name.delete_prefix('CrossPost::')

      # As Components::Statechart ids its checkpoints (+sc-<dom id>+).
      def dom_id(path) = path.to_s.gsub(/[^A-Za-z0-9_-]/, '-')

      # Every state of the chart, depth first, with the commands it inherits.
      def rows(region, inherited = [], acc = [])
        region[:states].each_value do |node|
          next if node[:type] == 'history'

          own = node[:on].values
          acc << Row.new(path: node[:id], type: node[:type], own:, inherited:, timers: node[:after].map { it[:delay] })
          case node[:type]
          in 'parallel' then regions(node).each { rows(it, inherited + own, acc) }
          in 'compound' then rows(node, inherited + own, acc)
          else nil
          end
        end
        acc
      end

      def each_node(region)
        region[:states].each_value.flat_map do |node|
          next [] if node[:type] == 'history'

          nested = case node[:type]
                   in 'parallel' then regions(node).flat_map { each_node(it) }
                   in 'compound' then each_node(node)
                   else []
                   end
          [node, *nested]
        end
      end

      # A parallel state's regions: its states, but for a history node.
      def regions(node) = node[:states].values.reject { it[:type] == 'history' }

      # Every command the machine takes somewhere, once each.
      def commands(chart) = each_node(chart).flat_map { it[:on].values }.uniq { it[:event] }

      # child group_id => the commands that start it, with where.
      def starters(chart)
        each_node(chart).each_with_object(Hash.new { |h, k| h[k] = [] }) do |node, acc|
          node[:on].each_value { |t| t[:starts].each { acc[it] << "#{t[:label]} (#{node[:id]})" } }
        end
      end

      def mounts(chart) = each_node(chart).flat_map { |node| node[:mounts].map { it[:src].delete_prefix('CrossPost::') } }.uniq

      # Whether +path+ is the node +id+ or inside it.
      def within?(path, id) = path == id || path.start_with?("#{id}.")

      # For each parallel state enclosing +path+, its other regions and the
      # commands their states take: accepted or not depending on where those
      # regions are. [[region id, transitions]].
      def sibling_regions(chart, path)
        each_node(chart).select { it[:type] == 'parallel' && path.start_with?("#{it[:id]}.") }.flat_map do |parallel|
          regions(parallel).reject { within?(path, it[:id]) }.map do |region|
            [region[:id], each_node(region).flat_map { it[:on].values }.uniq { it[:event] }]
          end
        end
      end

      # The chart with +path+ and the states enclosing it marked active, as
      # an instance's would be: Components::Statechart lights them and the
      # commands they accept.
      def highlight(region, path)
        region.merge(states: region[:states].transform_values { highlight_node(it, path) })
      end

      private def highlight_node(node, path)
        return node if node[:type] == 'history'

        states = case node[:type]
                 in 'parallel' then node[:states].transform_values { it[:type] == 'history' ? it : highlight(it, path) }
                 in 'compound' then highlight(node, path)[:states]
                 else node[:states]
                 end
        node.merge(states:, status: within?(path, node[:id]) ? { active: true, visited: true } : nil)
      end
    end
  end
end
