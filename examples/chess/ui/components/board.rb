# frozen_string_literal: true

require_relative 'square'

class Board < Sidereal::Components::BaseComponent
  FILES = %w[a b c d e f g h].freeze

  def initialize(fen:, viewer_color:, interactive:, game_id:)
    @fen = fen
    @viewer_color = viewer_color
    @interactive = interactive
    @game_id = game_id
  end

  def view_template
    div(id: 'board-wrap') do
      div(class: 'board', data: { flip: flipped? ? 'black' : 'white' }) do
        render_squares
      end
    end
  end

  private

  # Display the board from the viewer's perspective. White at the bottom
  # for white players and spectators; black at the bottom for black.
  def flipped? = @viewer_color == 'black'

  def render_squares
    ranks = parse_fen_ranks(@fen)
    rank_order = flipped? ? (1..8) : (8.downto(1))
    file_order = flipped? ? FILES.reverse : FILES

    rank_order.each do |rank|
      file_order.each do |file|
        coord = "#{file}#{rank}"
        piece = ranks[rank][FILES.index(file)]
        render Square.new(
          coord: coord,
          piece: piece,
          friendly: friendly?(piece),
          interactive: @interactive,
          game_id: @game_id
        )
      end
    end
  end

  # Parse the board portion of a FEN string into { rank => [piece_or_nil x 8] }
  # where piece is the FEN letter (uppercase = white).
  def parse_fen_ranks(fen)
    rows = fen.split(' ').first.split('/')
    out = {}
    rows.each_with_index do |row, i|
      rank = 8 - i
      cells = []
      row.each_char do |ch|
        if ch.match?(/\d/)
          ch.to_i.times { cells << nil }
        else
          cells << ch
        end
      end
      out[rank] = cells
    end
    out
  end

  def friendly?(piece)
    return false unless piece
    color = piece == piece.upcase ? 'white' : 'black'
    color == @viewer_color
  end
end
