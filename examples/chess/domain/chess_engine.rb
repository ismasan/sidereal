# frozen_string_literal: true

require 'chess'

# Thin wrapper over the `chess` gem (giuse/chess 0.5).
#
# The Game decider stores FEN in its state and rebuilds an engine on every
# command, so this wrapper is the single boundary that touches the gem. If
# the gem proves unsuitable, swap to another implementation with the same
# Result interface and the rest of the app keeps working.
#
# Notes on the chess 0.5 API (pinned by chess_engine_spec.rb):
#   - `Chess::Game.load_fen(fen)` rebuilds a game from a FEN string
#   - The `Game#move(uci)` accepts coord notation like "e2e4" and
#     auto-queens any pawn promotion when no piece letter is appended
#   - `Game#board` returns a `Chess::Board` exposing `to_fen`, `check?`,
#     `checkmate?`, `stalemate?`, and `[index]` (FEN piece char or nil)
class ChessEngine
  INITIAL_FEN = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'

  Result = Data.define(:legal, :san, :fen_after, :captured_piece,
                       :check, :checkmate, :stalemate)

  ILLEGAL = Result.new(legal: false, san: nil, fen_after: nil, captured_piece: nil,
                       check: false, checkmate: false, stalemate: false).freeze

  def initialize(fen)
    @fen = fen
    @game = Chess::Game.load_fen(fen)
  end

  # Side to move from FEN (the field after the board layout).
  def side_to_move
    @fen.split(' ')[1] == 'w' ? 'white' : 'black'
  end

  # Apply a move from coord-from to coord-to (e.g. 'e2', 'e4').
  # The chess gem auto-queens any pawn promotion when no promotion
  # letter is appended.
  def apply(from, to)
    captured = piece_at(to) || en_passant_capture(from, to)
    san = @game.move("#{from}#{to}")
    board = @game.board
    Result.new(
      legal: true,
      san: san,
      fen_after: board.to_fen,
      captured_piece: captured,
      check: !!board.check?,
      checkmate: !!board.checkmate?,
      stalemate: !!board.stalemate?
    )
  rescue Chess::IllegalMoveError, ArgumentError
    ILLEGAL
  end

  # Lowercase piece letter at a coord ('p','n','b','r','q','k') or nil.
  # Color is irrelevant for capture tracking — we only need the role.
  def piece_at(coord)
    idx = coord_to_index(coord)
    return nil unless idx
    raw = @game.board[idx]
    return nil if raw.nil? || raw == ' ' || raw == ''
    raw.to_s.downcase
  end

  private

  def coord_to_index(coord)
    return nil unless coord.is_a?(String) && coord.length == 2
    file = coord[0].ord - 'a'.ord
    rank = coord[1].to_i - 1
    return nil if file < 0 || file > 7 || rank < 0 || rank > 7
    rank * 8 + file
  end

  # En passant: a pawn moves diagonally to an empty square. The captured
  # piece is recorded as a pawn (the only piece that can be captured en
  # passant). We don't need to compute the captured pawn's location for
  # display purposes — only the piece role matters for the score sidebar.
  def en_passant_capture(from, to)
    return nil unless piece_at(from) == 'p'
    return nil if from[0] == to[0]   # same file = not a capture
    return nil if piece_at(to)       # already detected as a normal capture
    'p'
  end
end
