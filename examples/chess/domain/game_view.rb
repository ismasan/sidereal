# frozen_string_literal: true

# In-memory projection for the GamePage.
#
# Reads Game events for a specific game_id and evolves them into a single
# State value. Not registered with Sourced — used only on-demand via
# `Sourced.load(GameView, game_id:)`.
class GameView < Sourced::Projector::EventSourced
  partition_by :game_id

  State = Struct.new(
    :game_id,
    :white_username,
    :black_username,
    :status,
    :end_reason,
    :winner,
    :fen,
    :move_count,
    :captured,
    :last_move,        # { from:, to:, san:, color: } or nil
    :check,            # boolean — set by latest move
    keyword_init: true
  )

  state do |values|
    State.new(
      game_id: values[:game_id],
      move_count: 0,
      captured: { 'white' => [], 'black' => [] },
      check: false
    )
  end

  evolve(Game::GameCreated) do |s, e|
    s.white_username = e.payload.white_username
    s.fen = e.payload.initial_fen
    s.status = 'created'
  end

  evolve(Game::PlayerJoined) do |s, e|
    s.black_username = e.payload.username if e.payload.color == 'black'
    s.status = 'in_progress' if s.white_username && s.black_username
  end

  evolve(Game::MoveMade) do |s, e|
    s.fen = e.payload.fen_after
    s.move_count += 1
    s.check = e.payload.check
    s.last_move = {
      from: e.payload.from,
      to: e.payload.to,
      san: e.payload.san,
      color: e.payload.color
    }
    if e.payload.captured_piece
      s.captured[e.payload.color] << e.payload.captured_piece
    end
  end

  evolve(Game::GameEnded) do |s, e|
    s.status = 'ended'
    s.end_reason = e.payload.reason
    s.winner = e.payload.winner
  end
end
