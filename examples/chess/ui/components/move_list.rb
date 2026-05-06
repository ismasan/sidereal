# frozen_string_literal: true

class MoveList < Sidereal::Components::BaseComponent
  def initialize(move_messages)
    @moves = move_messages
  end

  def view_template
    section(id: 'move-list', class: 'sidebar__section') do
      h3 { 'Moves' }
      if @moves.empty?
        p(class: 'lede small') { 'No moves yet.' }
      else
        ol(class: 'moves') do
          paired_moves.each do |row|
            li do
              span(class: 'moves__white') { row[:white] || '' }
              span(class: 'moves__black') { row[:black] || '' }
            end
          end
        end
      end
    end
  end

  private

  def paired_moves
    rows = []
    @moves.each_with_index do |m, i|
      idx = i / 2
      rows[idx] ||= {}
      key = i.even? ? :white : :black
      rows[idx][key] = annotated_san(m)
    end
    rows
  end

  def annotated_san(msg)
    san = msg.payload.san.to_s
    san += '#' if msg.payload.checkmate
    san += '+' if msg.payload.check && !msg.payload.checkmate && !san.end_with?('+')
    san
  end
end
