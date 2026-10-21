# frozen_string_literal: true

module UI
  module CrossPost
    # The cross-post machines, one at a time: the tree to pick a machine
    # from, its statechart, and for a state picked on the chart or in the
    # list, what it accepts and what it refuses. The picked state and the
    # states enclosing it are lit, as an instance's active configuration
    # would be, with the commands they accept.
    #
    # Picking patches the page in place (see App#render_in_place), so each
    # state has a URL of its own: /cross-post/explore/:machine/:state, the
    # state as its chart DOM id.
    class ExplorerPage < Sidereal::Page
      # @return [ExplorerPage, nil] nil for a machine or state that doesn't exist
      def self.build(slug, state = nil)
        machine = Charts.machine(slug)
        return unless machine

        page = new(machine, state)
        page if state.nil? || page.row
      end

      attr_reader :row

      def initialize(machine, state)
        @machine = machine
        @slug = Charts.slug(machine)
        @definition = machine.to_h
        @rows = Charts.rows(@definition)
        @rows_by_path = @rows.to_h { [it.path, it] }
        @row = state && @rows.find { Charts.dom_id(it.path) == state }
        # Labels more than one command shares (each service region's Select).
        @shared_labels = Charts.commands(@definition).map { it[:label] }.tally.select { _2 > 1 }.keys
      end

      def view_template
        div(id: 'cross-post-explorer', class: 'booking') do
          div(class: 'sky', aria: { hidden: 'true' })

          div(class: 'explorer') do
            render_nav
            main(class: 'explorer__main') do
              render_header
              render_chart
              @row ? render_state : render_overview
              render Components::StatechartLegend.new
            end
          end
        end
      end

      private

      # ---- Navigation ----

      def render_nav
        root = ::CrossPost::Account.to_h

        aside(class: 'explorer__nav', aria: { label: 'Machines and states' }) do
          p(class: 'eyebrow') { a(href: '/cross-post') { 'All definitions' } }

          h2(class: 'explorer__heading') { 'Machines' }
          ul(class: 'explorer__tree') do
            li do
              machine_link(::CrossPost::Account)
              mounted(::CrossPost::Account, root)
              ul do
                root[:children].each do |child|
                  machine = Object.const_get(child[:machine])
                  li do
                    machine_link(machine)
                    mounted(machine, machine.to_h)
                  end
                end
              end
            end
          end

          h2(class: 'explorer__heading') { "States of #{Charts.short_name(@machine)}" }
          state_list(@definition, class: 'explorer__states')
        end
      end

      # The chart's states as it nests them: a compound state's sub-states
      # under it, and a parallel state's regions under it, each with its own.
      def state_list(region, **attrs)
        ul(**attrs) do
          region[:states].each_value do |node|
            next if node[:type] == 'history'

            li do
              state_link(@rows_by_path.fetch(node[:id]))
              case node[:type]
              in 'parallel'
                ul do
                  Charts.regions(node).each do |sub|
                    li do
                      span(class: 'explorer__region') { sub[:key] }
                      state_list(sub)
                    end
                  end
                end
              in 'compound' then state_list(node)
              else nil
              end
            end
          end
        end
      end

      def state_link(row)
        current = row == @row
        href = current ? base_href : state_href(row)
        a(href:, class: "explorer__state explorer__state--#{row.type}", aria: { current: current ? 'true' : nil }, data: travel(href)) do
          plain row.path.split('.').last
        end
      end

      def machine_link(machine)
        href = "/cross-post/explore/#{Charts.slug(machine)}"
        a(href:, aria: { current: machine == @machine ? 'page' : nil }, data: travel(href)) { Charts.short_name(machine) }
      end

      # Parts are drawn inside the machine they're part of.
      # Grouped by namespace within the machine: Post mounts
      # Targets (X, Bluesky …) and Deliveries (X, Bluesky …).
      def mounted(machine, chart)
        names = Charts.mounts(chart).map { it.delete_prefix("#{Charts.short_name(machine)}::") }
        return if names.empty?

        groups = names.group_by { it.rpartition('::').first }.map do |namespace, members|
          namespace.empty? ? members.join(', ') : "#{namespace} (#{members.map { it.split('::').last }.join(', ')})"
        end
        span(class: 'explorer__mounts') { "mounts #{groups.join(', ')}" }
      end

      # ---- The machine ----

      def render_header
        p(class: 'eyebrow') { 'Cross-post explorer' }
        h1 { Charts.short_name(@machine) }
        p(class: 'explorer__lead') do
          plain "Partitioned by #{@definition[:partition_by].join(', ')}. "
          starters = Charts.starters(::CrossPost::Account.to_h)[@machine.group_id]
          plain "Started by #{starters.join(', ')} on Account. " if starters&.any?
          plain 'Pick a state, on the chart or in the list, to see what it accepts.'
        end
      end

      # A click on a checkpoint picks it: the chart ids them sc-<dom id>.
      def render_chart
        pick = "evt.target.closest('.statechart__node') && " \
               "@get('#{base_href}/' + evt.target.closest('.statechart__node').id.slice(3))"
        chart = @row ? Charts.highlight(@definition, @row.path) : @definition

        div(class: 'explorer__chart machine-view', data: { 'on:click' => pick }) do
          render Components::Statechart.new(chart, title: "#{Charts.short_name(@machine)} statechart")
        end
      end

      def render_overview
        section(class: 'explorer__panel', aria: { label: 'Commands' }) do
          h2 { 'Every command it takes' }
          transitions(Charts.commands(@definition))
          if (stop = @definition[:stop])
            p(class: 'explorer__note') do
              plain 'Its parent can stop it from any state: '
              code { stop[:label] }
              plain " → #{stop[:targets].join}."
            end
          end
        end
      end

      # ---- The picked state ----

      def render_state
        accepted = @row.accepted.map { it[:event] }
        siblings = Charts.sibling_regions(@definition, @row.path)
        siblings = siblings.map { |region, list| [region, list.reject { accepted.include?(it[:event]) }] }.reject { _2.empty? }
        maybe = siblings.flat_map(&:last).map { it[:event] }
        refused = Charts.commands(@definition).reject { (accepted + maybe).include?(it[:event]) }

        section(class: 'explorer__panel', aria: { label: "In #{@row.path}" }) do
          h2 do
            plain 'In '
            code { @row.path }
            span(class: 'explorer__type') { " #{@row.type}" }
          end
          @row.timers.each { |delay| p(class: 'explorer__note') { "⏱ A timer fires #{delay} after entering it." } }

          div(class: 'explorer__columns') do
            div do
              h3 { 'Accepts' }
              transitions(@row.own)
              if @row.inherited.any?
                h3(class: 'explorer__sub') { 'From the states around it' }
                transitions(@row.inherited)
              end
            end

            if siblings.any?
              div do
                h3 { 'Depends on its sibling regions' }
                p(class: 'explorer__note') { 'Accepted while the other regions are where these are taken.' }
                ul(class: 'explorer__commands') do
                  siblings.each do |region, list|
                    li do
                      code { region.split('.').last }
                      plain ': '
                      plain list.map { name(it) }.join(', ')
                    end
                  end
                end
              end
            end

            div do
              h3 { 'Refuses' }
              transitions(refused, refused: true)
            end
          end
        end
      end

      def transitions(list, refused: false)
        return p(class: 'explorer__note') { 'Nothing.' } if list.empty?

        ul(class: "explorer__commands#{' explorer__commands--refused' if refused}") do
          list.each do |t|
            li do
              code { name(t) }
              next if refused

              plain " → #{t[:targets].join(' | ')}" if t[:targets].any?
              plain ' | stays' if t[:optional] && t[:targets].any?
              plain ' (stays)' if t[:targets].empty?
              plain ", starts #{t[:starts].join(', ')}" if t[:starts].any?
            end
          end
        end
      end

      # The command's label, or its type within the machine where the label
      # is shared (targets.x.select).
      def name(transition)
        return transition[:label] unless @shared_labels.include?(transition[:label])

        transition[:event].delete_prefix("#{@machine.message_prefix}.")
      end

      # ---- Links ----

      def base_href = "/cross-post/explore/#{@slug}"
      def state_href(row) = "#{base_href}/#{Charts.dom_id(row.path)}"

      # Fetched over Datastar, which patches the page in, instead of loaded.
      def travel(href) = { 'on:click__prevent' => "@get('#{href}')" }
    end
  end
end
