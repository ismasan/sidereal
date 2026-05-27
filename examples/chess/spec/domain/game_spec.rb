# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Game do
  include Sourced::Testing::RSpec

  let(:game_id) { 'game-1' }
  let(:white)   { 'alice' }
  let(:black)   { 'bob' }
  let(:carol)   { 'carol' }

  describe Game::CreateGame do
    it 'creates a game with white assigned' do
      with_reactor(Game, game_id:)
        .when(Game::CreateGame, game_id:, white_username: white)
        .then(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
    end

    it 'silently no-ops on double-create (idempotent)' do
      with_reactor(Game, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .when(Game::CreateGame, game_id:, white_username: white)
        .then
    end

    it 'rejects an empty white_username (no session)' do
      with_reactor(Game, game_id:)
        .when(Game::CreateGame, game_id:, white_username: '')
        .then(RuntimeError, 'login required')
    end
  end

  describe Game::JoinGame do
    it 'seats black' do
      with_reactor(Game, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .when(Game::JoinGame, game_id:, username: black)
        .then(Game::PlayerJoined, game_id:, username: black, color: 'black')
    end

    it 'silently no-ops when white tries to also sit as black' do
      with_reactor(Game, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .when(Game::JoinGame, game_id:, username: white)
        .then
    end

    it 'silently no-ops when black is already taken (race / spectator)' do
      with_reactor(Game, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .and(Game::PlayerJoined, game_id:, username: black, color: 'black')
        .when(Game::JoinGame, game_id:, username: carol)
        .then
    end
  end

  describe Game::MakeMove do
    let(:setup) do
      with_reactor(Game, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .and(Game::PlayerJoined, game_id:, username: black, color: 'black')
    end

    it 'silently no-ops a move from a non-player (spectator)' do
      setup
        .when(Game::MakeMove, game_id:, username: carol, from: 'e2', to: 'e4')
        .then
    end

    it 'silently no-ops when it is not your turn' do
      setup
        .when(Game::MakeMove, game_id:, username: black, from: 'e7', to: 'e5')
        .then
    end

    it 'silently no-ops an illegal move' do
      setup
        .when(Game::MakeMove, game_id:, username: white, from: 'e2', to: 'e5')
        .then
    end

    it 'silently no-ops a move with no source selected' do
      setup
        .when(Game::MakeMove, game_id:, username: white, from: '', to: 'e4')
        .then
    end

    it 'emits MoveMade with engine-derived fields' do
      setup
        .when(Game::MakeMove, game_id:, username: white, from: 'e2', to: 'e4')
        .then { |result|
          expect(result.messages.size).to eq(1)
          evt = result.messages.first
          expect(evt).to be_a(Game::MoveMade)
          expect(evt.payload.color).to eq('white')
          expect(evt.payload.san).to match(/e4/)
          expect(evt.payload.fen_after).to include(' b ')
          expect(evt.payload.captured_piece).to be_nil
        }
    end
  end

  describe Game::Resign do
    it 'ends the game with the other side as winner' do
      with_reactor(Game, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .and(Game::PlayerJoined, game_id:, username: black, color: 'black')
        .when(Game::Resign, game_id:, username: white)
        .then(Game::GameEnded, game_id:, reason: 'resignation', winner: 'black')
    end

    it 'silently no-ops when the game is not in progress' do
      with_reactor(Game, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .when(Game::Resign, game_id:, username: white)
        .then
    end
  end
end
