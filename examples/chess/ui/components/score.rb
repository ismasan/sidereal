# frozen_string_literal: true

class Score < Sidereal::Components::BaseComponent
  PIECE_VALUES = { 'p' => 1, 'n' => 3, 'b' => 3, 'r' => 5, 'q' => 9, 'k' => 0 }.freeze

  GLYPHS_BLACK = { 'p' => "♟", 'n' => "♞", 'b' => "♝", 'r' => "♜", 'q' => "♛" }.freeze
  GLYPHS_WHITE = { 'p' => "♙", 'n' => "♘", 'b' => "♗", 'r' => "♖", 'q' => "♕" }.freeze

  def initialize(captured)
    @captured = captured || { 'white' => [], 'black' => [] }
  end

  def view_template
    section(id: 'score', class: 'sidebar__section') do
      h3 { 'Captured' }

      div(class: 'score') do
        div(class: 'score__side score__side--white') do
          render_pieces(@captured['white'], GLYPHS_BLACK) # white captures black pieces
        end
        div(class: 'score__delta') { delta_label }
        div(class: 'score__side score__side--black') do
          render_pieces(@captured['black'], GLYPHS_WHITE) # black captures white pieces
        end
      end
    end
  end

  private

  def render_pieces(pieces, glyphs)
    pieces.sort_by { |p| -PIECE_VALUES.fetch(p, 0) }.each do |p|
      span(class: 'score__piece') { plain glyphs.fetch(p, '?') }
    end
  end

  def delta_label
    white_value = @captured['white'].sum { |p| PIECE_VALUES.fetch(p, 0) }
    black_value = @captured['black'].sum { |p| PIECE_VALUES.fetch(p, 0) }
    diff = white_value - black_value
    return '=' if diff.zero?
    diff.positive? ? "W +#{diff}" : "B +#{-diff}"
  end
end
