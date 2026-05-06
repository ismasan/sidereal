# frozen_string_literal: true

class Piece < Sidereal::Components::BaseComponent
  GLYPHS = {
    'K' => "♔", 'Q' => "♕", 'R' => "♖",
    'B' => "♗", 'N' => "♘", 'P' => "♙",
    'k' => "♚", 'q' => "♛", 'r' => "♜",
    'b' => "♝", 'n' => "♞", 'p' => "♟"
  }.freeze

  NAMES = {
    'K' => 'White king', 'Q' => 'White queen', 'R' => 'White rook',
    'B' => 'White bishop', 'N' => 'White knight', 'P' => 'White pawn',
    'k' => 'Black king', 'q' => 'Black queen', 'r' => 'Black rook',
    'b' => 'Black bishop', 'n' => 'Black knight', 'p' => 'Black pawn'
  }.freeze

  def initialize(code)
    @code = code
  end

  def view_template
    return if @code.nil? || @code.empty?
    color = @code == @code.upcase ? 'white' : 'black'
    span(class: "piece piece--#{color}", aria_label: NAMES.fetch(@code, @code)) do
      plain GLYPHS.fetch(@code, '?')
    end
  end
end
