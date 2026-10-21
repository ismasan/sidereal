# frozen_string_literal: true

module UI
  module CrossPost
    # The cross-posting app as a tree of machines, from their definitions:
    # which machine starts which, each one's statechart, and, state by state,
    # the commands it accepts. Anything a state doesn't list (or inherit from
    # the states around it) is refused there.
    class DefinitionsPage < Sidereal::Page
      path '/cross-post'

      def self.load(_params, _ctx) = new

      def view_template
        div(class: 'booking') do
          div(class: 'sky', aria: { hidden: 'true' })

          main(class: 'definitions') do
            p(class: 'eyebrow') { a(href: '/') { 'Sidereal' } }
            h1 { 'A cross-posting app, as statecharts' }
            p(class: 'definitions__lead') do
              a(href: '/cross-post/explore/account') { 'Explore it interactively' }
            end
            p(class: 'definitions__lead') do
              plain 'The whole app is an Account machine and the children it starts: a session per login, '
              plain 'a connection per service (each with its own auth handshake), and a post per post. '
              plain 'Each state lists the commands it accepts; any other command is refused there.'
            end

            render_tree
            ::CrossPost.machines.each { render_machine(it) }
            render Components::StatechartLegend.new
          end
        end
      end

      private

      def render_tree
        root = ::CrossPost::Account.to_h
        starters = Charts.starters(root)

        section(class: 'definitions__chart', aria: { label: 'Machine tree' }) do
          h2 { 'The tree' }
          ul(class: 'machine-tree') do
            li do
              a(href: "##{anchor(::CrossPost::Account)}") { code { 'CrossPost::Account' } }
              plain " · mounts #{Charts.mounts(root).join(', ')}" if Charts.mounts(root).any?
              ul do
                root[:children].each do |child|
                  machine = Object.const_get(child[:machine])
                  li do
                    a(href: "##{anchor(machine)}") { code { child[:machine] } }
                    plain " · started by #{starters.fetch(child[:id], []).join(', ')}"
                    plain " · stopped on #{child[:stop_on].join(', ')}" if child[:stop_on].any?
                    nested = Charts.mounts(machine.to_h)
                    plain " · mounts #{nested.join(', ')}" if nested.any?
                  end
                end
              end
            end
          end
        end
      end

      def render_machine(machine)
        chart = machine.to_h
        name = machine.name.delete_prefix('CrossPost::')

        section(id: anchor(machine), class: 'definitions__chart machine-view', aria: { label: "#{name} statechart" }) do
          h2 { name }
          p(class: 'definitions__lead') { "Partitioned by #{chart[:partition_by].join(', ')}." }
          render Components::Statechart.new(chart, title: "#{name} statechart")
          render_commands(Charts.rows(chart))
          details(class: 'machine-view__value') do
            summary { 'Mermaid' }
            pre { machine.to_mermaid }
          end
        end
      end

      def render_commands(rows)
        table(class: 'command-table') do
          thead do
            tr do
              th { 'State' }
              th { 'Accepts' }
              th { 'Also accepts, from enclosing states' }
            end
          end
          tbody do
            rows.each do |row|
              tr(class: "command-table__row--#{row.type}") do
                td do
                  code { row.path }
                  row.timers.each { |delay| span(class: 'command-table__timer') { " ⏱ #{delay}" } }
                end
                td { commands(row.own) }
                td { commands(row.inherited) }
              end
            end
          end
        end
      end

      def commands(transitions)
        return plain('—') if transitions.empty?

        ul(class: 'command-table__commands') do
          transitions.each do |t|
            li do
              code { t[:label] }
              plain " → #{t[:targets].join(' | ')}" if t[:targets].any?
              plain ' | stay' if t[:optional] && t[:targets].any?
              plain " (starts #{t[:starts].join(', ')})" if t[:starts].any?
            end
          end
        end
      end

      def anchor(machine) = Charts.slug(machine)
    end
  end
end
