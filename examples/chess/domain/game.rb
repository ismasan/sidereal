# frozen_string_literal: true

require_relative 'chess_engine'

# Event-sourced chess game.
#
# Stores the FEN of the current position in state, plus seat assignments and
# a captured-pieces ledger. The chess engine is reconstructed from FEN on
# every MakeMove — cheap enough for a demo, and keeps state minimal.
class Game < Sourced::Decider
  consumer_group 'games'
  partition_by :game_id

  # ---- Commands ----

  # Username fields default to '' so client form payloads can omit them —
  # `before_command` stamps the real value from the session before the
  # command runs. Decider handlers guard against the empty case.
  CreateGame = Sourced::Command.define('chess.create_game') do
    attribute :game_id, Sourced::Types::AutoUUID
    attribute :white_username, Sourced::Types::String.default('')
  end

  JoinGame = Sourced::Command.define('chess.join_game') do
    attribute :game_id, Sourced::Types::UUID::V4
    attribute :username, Sourced::Types::String.default('')
  end

  # `from` / `to` default to '' so the click-to-move target form can
  # post even when no source is selected (Plumb validation will pass
  # and the decider's command handler raises 'no source selected'
  # which routes to the on_fail logger). Avoids the
  # `patch_command_errors` JS path that expects wrapper divs we don't
  # render around hidden inputs.
  MakeMove = Sourced::Command.define('chess.make_move') do
    attribute :game_id, Sourced::Types::UUID::V4
    attribute :username, Sourced::Types::String.default('')
    attribute :from, Sourced::Types::String.default('')
    attribute :to, Sourced::Types::String.default('')
  end

  Resign = Sourced::Command.define('chess.resign') do
    attribute :game_id, Sourced::Types::UUID::V4
    attribute :username, Sourced::Types::String.default('')
  end

  # ---- Events ----

  GameCreated = Sourced::Event.define('chess.game_created') do
    attribute :game_id, Sourced::Types::UUID::V4
    attribute :white_username, Sourced::Types::String.present
    attribute :initial_fen, Sourced::Types::String.present
  end

  PlayerJoined = Sourced::Event.define('chess.player_joined') do
    attribute :game_id, Sourced::Types::UUID::V4
    attribute :username, Sourced::Types::String.present
    attribute :color, Sourced::Types::String.present
  end

  MoveMade = Sourced::Event.define('chess.move_made') do
    attribute :game_id, Sourced::Types::UUID::V4
    attribute :username, Sourced::Types::String.present
    attribute :color, Sourced::Types::String.present
    attribute :from, Sourced::Types::String.present
    attribute :to, Sourced::Types::String.present
    attribute :san, Sourced::Types::String.present
    attribute :fen_after, Sourced::Types::String.present
    attribute? :captured_piece, Sourced::Types::String
    attribute :check, Sourced::Types::Boolean.default(false)
    attribute :checkmate, Sourced::Types::Boolean.default(false)
    attribute :stalemate, Sourced::Types::Boolean.default(false)
  end

  GameEnded = Sourced::Event.define('chess.game_ended') do
    attribute :game_id, Sourced::Types::UUID::V4
    attribute :reason, Sourced::Types::String.present
    attribute? :winner, Sourced::Types::String
  end

  # ---- State ----

  State = Struct.new(
    :game_id,
    :white_username,
    :black_username,
    :status,         # nil | 'created' | 'in_progress' | 'ended'
    :end_reason,
    :winner,
    :fen,
    :move_count,
    :captured,       # { 'white' => ['p','n'], 'black' => ['p'] } (capturer's color)
    keyword_init: true
  )

  state do |values|
    State.new(
      game_id: values[:game_id],
      move_count: 0,
      captured: { 'white' => [], 'black' => [] }
    )
  end

  # ---- Evolve transitions ----

  evolve(GameCreated) do |s, e|
    s.white_username = e.payload.white_username
    s.fen = e.payload.initial_fen
    s.status = 'created'
  end

  evolve(PlayerJoined) do |s, e|
    s.black_username = e.payload.username if e.payload.color == 'black'
    s.status = 'in_progress' if s.white_username && s.black_username
  end

  evolve(MoveMade) do |s, e|
    s.fen = e.payload.fen_after
    s.move_count += 1
    if e.payload.captured_piece
      s.captured[e.payload.color] << e.payload.captured_piece
    end
  end

  evolve(GameEnded) do |s, e|
    s.status = 'ended'
    s.end_reason = e.payload.reason
    s.winner = e.payload.winner
  end

  # ---- Command handlers ----

  command(CreateGame) do |state, cmd|
    return if state.status                # idempotent — re-create is a silent no-op
    raise 'login required' if cmd.payload.white_username.to_s.empty?

    event GameCreated,
      game_id: cmd.payload.game_id,
      white_username: cmd.payload.white_username,
      initial_fen: ChessEngine::INITIAL_FEN
  end

  # Silent no-op when the requester is already white or when black is
  # already taken — makes the "Sit as black" button safe under double-click
  # and concurrent visitors. Sourced serializes commands per partition, so
  # a race between two visitors resolves with the second one becoming a
  # spectator.
  command(JoinGame) do |state, cmd|
    return unless state.status                  # game not yet created — silent no-op
    return if cmd.payload.username == state.white_username
    return if state.black_username              # seat taken — visitor becomes spectator

    event PlayerJoined,
      game_id: cmd.payload.game_id,
      username: cmd.payload.username,
      color: 'black'
  end

  command(MakeMove) do |state, cmd|
    # Empty payloads / wrong-state moves are silent no-ops so the consumer
    # group doesn't halt on rejected attempts (e.g. user clicks a target
    # before selecting a source). Only domain-rule violations raise.
    return unless state.status == 'in_progress'
    return if cmd.payload.from.to_s.empty?
    return if cmd.payload.to.to_s.empty?

    color = color_for(state, cmd.payload.username)
    return unless color                         # spectator click — silent no-op

    engine = ChessEngine.new(state.fen)
    return unless engine.side_to_move == color  # off-turn click — silent no-op

    result = engine.apply(cmd.payload.from, cmd.payload.to)
    return unless result.legal                  # illegal move shape — silent no-op

    event MoveMade,
      game_id: cmd.payload.game_id,
      username: cmd.payload.username,
      color: color,
      from: cmd.payload.from,
      to: cmd.payload.to,
      san: result.san,
      fen_after: result.fen_after,
      captured_piece: result.captured_piece,
      check: result.check,
      checkmate: result.checkmate,
      stalemate: result.stalemate

    if result.checkmate
      event GameEnded, game_id: cmd.payload.game_id, reason: 'checkmate', winner: color
    elsif result.stalemate
      event GameEnded, game_id: cmd.payload.game_id, reason: 'stalemate', winner: nil
    end
  end

  command(Resign) do |state, cmd|
    return unless state.status == 'in_progress'
    color = color_for(state, cmd.payload.username)
    return unless color                          # spectator click — no-op

    event GameEnded,
      game_id: cmd.payload.game_id,
      reason: 'resignation',
      winner: color == 'white' ? 'black' : 'white'
  end

  private def color_for(state, username)
    return 'white' if username == state.white_username
    return 'black' if username == state.black_username
    nil
  end

  # ---- Bridge to Sidereal SSE ----

  after_sync do |state:, events:, **|
    events.each do |evt|
      ch = Sidereal.channels.for(evt)
      Console.info("[chess] publishing #{evt.type} → #{ch}")
      Sidereal.pubsub.publish(ch, evt)
    end
  end
end
