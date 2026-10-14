# frozen_string_literal: true

module UI
  module Components
    # What Statechart's shapes, colours and lines mean. Each swatch is drawn
    # with the chart's own classes, so the two can't drift apart.
    class StatechartLegend < Sidereal::Components::BaseComponent
      W = 40
      H = 22

      ITEMS = [
        [:active, 'Active checkpoint: where the booking is now'],
        [:visited, 'Visited since its region was entered'],
        [:checkpoint, 'Checkpoint not reached'],
        [:final, 'Final checkpoint: its region is done'],
        [:initial, "A region's initial position"],
        [:region, 'Region: runs in parallel with its siblings'],
        [:live, 'Command the booking accepts now'],
        [:command, 'Command, and the checkpoint it decides into'],
        [:done, 'done: taken by itself once every region is final'],
        [:data, 'Command that only records data, and stays put'],
        [:timer, 'Timer: a command dispatched that long after entering']
      ].freeze

      def view_template
        ul(class: 'legend', aria: { label: 'Legend' }) do
          ITEMS.each do |kind, text|
            li(class: 'legend__item') do
              svg(class: 'legend__swatch', viewBox: "0 0 #{W} #{H}", width: W, height: H, aria: { hidden: 'true' }) do |s|
                swatch(s, kind)
              end
              span { text }
            end
          end
        end
      end

      private

      def swatch(s, kind)
        case kind
        when :active, :visited, :checkpoint
          state = { active: ' is-active', visited: ' is-visited', checkpoint: '' }.fetch(kind)
          s.g(class: "statechart__node statechart__node--atomic#{state}") do
            s.rect(x: 4, y: 4, width: 32, height: 14, rx: 4, class: 'statechart__box')
          end
        when :final
          s.g(class: 'statechart__node statechart__node--final') do
            s.rect(x: 4, y: 3, width: 32, height: 16, rx: 4, class: 'statechart__box')
            s.rect(x: 7, y: 6, width: 26, height: 10, rx: 3, class: 'statechart__final-ring')
          end
        when :initial
          s.g(class: 'statechart__node statechart__node--initial') do
            s.circle(cx: 20, cy: 11, r: 6, class: 'statechart__dot')
          end
        when :region
          s.g(class: 'statechart__region') do
            s.rect(x: 3, y: 3, width: 34, height: 16, rx: 4, class: 'statechart__region-box')
          end
        when :live, :command, :done
          classes = { live: 'statechart__edge--live is-live', command: 'statechart__edge--command',
                      done: 'statechart__edge--done' }.fetch(kind)
          s.g(class: "statechart__edge #{classes}") do
            s.path(d: 'M 4 11 L 30 11')
            s.polygon(points: '29,7 36,11 29,15', class: kind == :live ? 'statechart__arrow-live' : 'statechart__arrow')
          end
        when :data
          s.g(class: 'statechart__node statechart__node--initial') do
            s.circle(cx: 12, cy: 11, r: 5, class: 'statechart__dot')
          end
          s.g(class: 'statechart__edge statechart__edge--data') do
            s.path(d: 'M 17 8 C 34 0, 34 22, 20 15')
            s.polygon(points: '23,12 17,14 22,18', class: 'statechart__arrow')
          end
        when :timer
          s.text(x: 20, y: 15, class: 'statechart__timer legend__timer', 'text-anchor': 'middle') { '⏱ 60s' }
        end
      end
    end
  end
end
