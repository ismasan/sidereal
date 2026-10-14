# frozen_string_literal: true

module UI
  module Components
    # Draws a Sourced::Machine as an SVG statechart, from the Hash that
    # Machine#to_h returns (Machine.to_h for the definition alone). Works for
    # any machine: it lays out whatever regions and checkpoints the Hash has.
    #
    # Layout: each region stacks its checkpoints in rows, ranked by how many
    # transitions they are from the region's initial position, so most arrows
    # point down. A parallel checkpoint draws its regions side by side inside
    # its box, nested as deep as they go. Arrows are drawn last, over the
    # boxes, from absolute positions.
    #
    # With an instance's status, the active checkpoints are lit, visited ones
    # marked, inactive regions dimmed, and the transitions the machine can take
    # next highlighted.
    class Statechart < Sidereal::Components::BaseComponent
      CHAR_W = 6.7       # average label glyph width at the chart's font size
      NODE_H = 30
      NODE_PAD = 14
      DOT = 8            # radius of a region's initial position
      GAP_X = 18
      GAP_Y = 46         # room for an arrow and its label between rows
      PAD = 14
      REGION_HEAD = 22
      PARALLEL_HEAD = 30
      LOOP = 26          # how far a self-transition loops out
      EDGE_CHAR_W = 6.0  # the same, for arrow labels

      # +extra+ is room kept free to the right of a box, for its self-loops' labels.
      # +gaps+ is the space between neighbours in each row of a region.
      Box = Struct.new(:kind, :data, :w, :h, :x, :y, :children, :rows, :gaps, :extra, keyword_init: true) do
        def slot_w = w + extra.to_i
        def cx = x + w / 2.0
        def cy = y + h / 2.0
        def right = x + w
        def bottom = y + h
      end

      Edge = Data.define(:from, :to, :label, :kind)

      # @param chart [Hash] Machine#to_h or Machine.to_h
      # @param title [String] accessible name for the drawing
      def initialize(chart, title: nil)
        @chart = chart
        @title = title || "#{chart[:machine]} statechart"
        @boxes = {}
      end

      def view_template
        root = layout_region(@chart, root: true)
        place(root, 0, 0)
        edges = collect_edges(@chart)

        svg(
          id: 'statechart',
          class: 'statechart',
          viewBox: "-8 -8 #{(root.w + 16).round} #{(root.h + 16).round}",
          role: 'img',
          aria: { label: @title }
        ) do |s|
          s.title { @title }
          s.defs do
            %w[arrow arrow-live].each do |name|
              s.marker(id: "sc-#{name}", viewBox: '0 0 10 10', refX: 9, refY: 5,
                       markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse') do
                s.path(d: 'M 0 1 L 9 5 L 0 9 z', class: "statechart__#{name}")
              end
            end
          end

          draw_region_contents(s, root)
          edges.each { |edge| draw_edge(s, edge) }
        end
      end

      private

      # ---- Layout: sizes, relative to each box's own origin ----

      def layout_region(region, root: false)
        states = region[:states].values
        ranks = rank(region, states)
        rows = states.group_by { |state| ranks.fetch(state[:id]) }.sort.map do |_, members|
          members.map { |state| layout_node(state) }
        end
        gaps = rows.map { |row| row_gap(row, ranks) }

        head = root ? 0 : REGION_HEAD
        pad = root ? 0 : PAD
        inner_w = rows.zip(gaps).map { |row, gap| row_width(row, gap) }.max || 0
        inner_h = rows.sum { |row| row.map(&:h).max } + GAP_Y * [rows.size - 1, 0].max

        Box.new(kind: root ? :root : :region, data: region, rows:, gaps:, children: rows.flatten,
                w: inner_w + pad * 2, h: head + inner_h + pad * 2)
      end

      def row_width(row, gap) = row.sum(&:slot_w) + gap * (row.size - 1)

      # Wide enough for the label of an arrow between two checkpoints of a row.
      def row_gap(row, ranks)
        ids = row.map { |box| box.data[:id] }
        labels = row.flat_map do |box|
          transitions(box.data).filter_map { |label, target| label if target != box.data[:id] && ids.include?(target) }
        end
        [GAP_X, *labels.map { |label| text_width(label) + 28 }].max
      end

      def layout_node(state)
        box = case state[:type]
              when 'initial'
                Box.new(w: DOT * 2, h: DOT * 2, children: [])
              when 'parallel'
                regions = state[:states].values.map { |region| layout_region(region) }
                w = row_width(regions, GAP_X) + PAD * 2
                w = [w, label_width(state) + PAD * 2].max
                Box.new(w:, h: PARALLEL_HEAD + regions.map(&:h).max + PAD, children: regions)
              else
                Box.new(w: label_width(state), h: NODE_H, children: [])
              end
        box.kind = state[:type].to_sym
        box.data = state
        loops = transitions(state).filter_map { |label, target| label if target == state[:id] }
        box.extra = loops.any? ? LOOP + loops.map { |label| text_width(label) }.max + 8 : 0
        @boxes[state[:id]] = box
        box
      end

      def label_width(state)
        timer = state[:after].any? ? 52 : 0
        [(state[:key].length * CHAR_W) + NODE_PAD * 2 + timer, 72].max
      end

      # Rows: breadth-first from the initial position, following transitions
      # that stay in this region. A checkpoint reached by nothing goes last.
      def rank(region, states)
        ids = states.to_h { |state| [state[:id], state] }
        ranks = { region[:initial] => 0 }
        queue = [region[:initial]]
        while (id = queue.shift)
          next_ids(ids.fetch(id)).each do |target|
            next unless ids.key?(target) && !ranks.key?(target)

            ranks[target] = ranks.fetch(id) + 1
            queue << target
          end
        end
        last = (ranks.values.max || 0) + 1
        states.each { |state| ranks[state[:id]] ||= last }
        ranks
      end

      # The main path first: a join, then commands in definition order.
      def next_ids(state) = transitions(state).map(&:last)

      # [label, target id] for each arrow out of +state+. A data-only command
      # stays where it is, so it's drawn as a loop.
      def transitions(state)
        done = state[:on_done] ? [['done', state[:on_done]]] : []
        done + state[:on].values.flat_map do |t|
          t[:targets].empty? ? [[t[:label], state[:id]]] : t[:targets].map { |target| [t[:label], target] }
        end
      end

      def text_width(label) = label.length * EDGE_CHAR_W

      # ---- Placement: absolute positions ----

      def place(box, x, y)
        box.x = x
        box.y = y

        case box.kind
        when :root, :region
          head = box.kind == :root ? 0 : REGION_HEAD
          pad = box.kind == :root ? 0 : PAD
          row_y = y + head + pad
          box.rows.zip(box.gaps).each do |row, gap|
            row_h = row.map(&:h).max
            col_x = x + (box.w - row_width(row, gap)) / 2.0
            row.each do |child|
              place(child, col_x, row_y + (row_h - child.h) / 2.0)
              col_x += child.slot_w + gap
            end
            row_y += row_h + GAP_Y
          end
        when :parallel
          used = row_width(box.children, GAP_X)
          col_x = x + (box.w - used) / 2.0
          box.children.each do |region|
            place(region, col_x, y + PARALLEL_HEAD)
            col_x += region.w + GAP_X
          end
        end
      end

      # ---- Drawing ----

      def draw_region_contents(s, region)
        region.children.each { |child| draw_node(s, child) }
      end

      def draw_region(s, region)
        status = region.data[:status]
        classes = ['statechart__region']
        classes << 'is-inactive' if status && !status[:active]
        classes << 'is-done' if status&.dig(:done)

        s.g(class: classes.join(' '), id: "sc-region-#{region.data[:id]}") do
          s.rect(x: region.x, y: region.y, width: region.w, height: region.h, rx: 10, class: 'statechart__region-box')
          s.text(x: region.x + 10, y: region.y + 15, class: 'statechart__region-name') { region.data[:key] }
          draw_region_contents(s, region)
        end
      end

      def draw_node(s, box)
        state = box.data
        status = state[:status]
        classes = ['statechart__node', "statechart__node--#{state[:type]}"]
        classes << 'is-active' if status&.dig(:active)
        classes << 'is-visited' if status&.dig(:visited) && !status[:active]

        s.g(class: classes.join(' '), id: "sc-#{node_dom_id(state[:id])}") do
          s.title { node_title(state) }
          case box.kind
          when :initial
            s.circle(cx: box.cx, cy: box.cy, r: DOT, class: 'statechart__dot')
          when :parallel
            s.rect(x: box.x, y: box.y, width: box.w, height: box.h, rx: 14, class: 'statechart__box')
            s.text(x: box.x + 14, y: box.y + 20, class: 'statechart__label') { state[:key] }
            s.text(x: box.right - 14, y: box.y + 20, class: 'statechart__hint', 'text-anchor': 'end') { 'parallel' }
            box.children.each { |region| draw_region(s, region) }
          else
            s.rect(x: box.x, y: box.y, width: box.w, height: box.h, rx: 8, class: 'statechart__box')
            if box.kind == :final
              s.rect(x: box.x + 3, y: box.y + 3, width: box.w - 6, height: box.h - 6, rx: 6, class: 'statechart__final-ring')
            end
            label_x = state[:after].any? ? box.x + NODE_PAD : box.cx
            s.text(x: label_x, y: box.cy + 4, class: 'statechart__label',
                   'text-anchor': state[:after].any? ? 'start' : 'middle') { state[:key] }
            if (timer = state[:after].first)
              s.text(x: box.right - NODE_PAD, y: box.cy + 4, class: 'statechart__timer', 'text-anchor': 'end') do
                "⏱ #{timer[:delay].to_i}s"
              end
            end
          end
        end
      end

      def node_title(state)
        return 'initial position' if state[:type] == 'initial'

        text = "#{state[:key]} (#{state[:message_type]})"
        if (entered = state.dig(:status, :entered_by))
          text += " — entered #{Time.iso8601(entered[:at]).localtime.strftime('%H:%M:%S')}"
        end
        text
      end

      def collect_edges(region, edges = [])
        region[:states].each_value do |state|
          live = state.dig(:status, :active)
          state[:on].each_value do |transition|
            if transition[:targets].empty?
              edges << Edge.new(from: state[:id], to: state[:id], label: transition[:label], kind: live ? :data_live : :data)
            else
              transition[:targets].each do |target|
                edges << Edge.new(from: state[:id], to: target, label: transition[:label], kind: live ? :live : :command)
              end
            end
          end
          edges << Edge.new(from: state[:id], to: state[:on_done], label: 'done', kind: :done) if state[:on_done]
          state[:states].each_value { |child| collect_edges(child, edges) } if state[:type] == 'parallel'
        end
        edges
      end

      def draw_edge(s, edge)
        from = @boxes.fetch(edge.from)
        to = @boxes.fetch(edge.to)
        path, label_at = route(from, to)
        live = %i[live data_live].include?(edge.kind)
        classes = ['statechart__edge', "statechart__edge--#{edge.kind}"]
        classes << 'is-live' if live

        s.g(class: classes.join(' ')) do
          s.path(d: path, 'marker-end': "url(#sc-#{live ? 'arrow-live' : 'arrow'})")
          s.text(x: label_at[0], y: label_at[1], class: 'statechart__edge-label', 'text-anchor': label_at[2]) do
            edge.label
          end
        end
      end

      # A path between two boxes, and where its label goes: [x, y, anchor].
      def route(from, to)
        if from.equal?(to)
          self_loop(from)
        elsif to.y >= from.bottom - 1
          # Straight down where the boxes overlap horizontally, so arrows
          # leaving a wide box don't share a starting point.
          x1 = to.cx.clamp(from.x + 12, [from.right - 12, from.x + 12].max)
          x2 = from.cx.clamp(to.x + 12, [to.right - 12, to.x + 12].max)
          x2 = x1 if x1.between?(to.x + 12, to.right - 12)
          x1 = from.cx if from.kind == :initial
          x2 = to.cx if to.kind == :initial
          y1 = from.bottom
          y2 = to.y
          bend = [(y2 - y1) / 2.0, 18].max
          path = "M #{f x1} #{f y1} C #{f x1} #{f(y1 + bend)}, #{f x2} #{f(y2 - bend)}, #{f x2} #{f y2}"
          label_x = (x1 + x2) / 2.0
          [path, [label_x + 6, (y1 + y2) / 2.0 + 4, 'start']]
        else
          # Beside, or above: leave from the side facing the target.
          rightward = to.cx >= from.cx
          x1 = rightward ? from.right : from.x
          x2 = rightward ? to.x : to.right
          y1 = from.cy
          y2 = to.cy
          dx = (x2 - x1) / 2.0
          path = "M #{f x1} #{f y1} C #{f(x1 + dx)} #{f y1}, #{f(x2 - dx)} #{f y2}, #{f x2} #{f y2}"
          [path, [(x1 + x2) / 2.0, (y1 + y2) / 2.0 - 6, 'middle']]
        end
      end

      def self_loop(box)
        x = box.right
        y = box.kind == :parallel ? box.y + 18 : box.cy
        path = "M #{f x} #{f(y - 6)} C #{f(x + LOOP)} #{f(y - 18)}, #{f(x + LOOP)} #{f(y + 18)}, #{f x} #{f(y + 6)}"
        [path, [x + LOOP - 2, y + 4, 'start']]
      end

      def f(n) = n.round(1)

      def node_dom_id(id) = id.to_s.gsub(/[^A-Za-z0-9_-]/, '-')
    end
  end
end
