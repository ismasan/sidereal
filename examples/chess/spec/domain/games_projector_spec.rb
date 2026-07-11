# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GamesProjector do
  include Sourced::Testing::RSpec

  let(:test_db) { Sequel.sqlite }

  before do
    test_db.create_table(:games) do
      String :game_id, primary_key: true
      String :white_username, null: false
      String :black_username
      String :status, null: false
      String :end_reason
      String :winner
      Integer :move_count, default: 0, null: false
      String :created_at, null: false
    end

    allow(Sourced).to receive_message_chain(:store, :db).and_return(test_db)
  end

  let(:game_id) { 'game-1' }
  let(:white)   { 'alice' }
  let(:black)   { 'bob' }

  describe 'evolve' do
    it 'projects an open game from GameCreated' do
      with_reactor(GamesProjector, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .then { |result|
          expect(result.state).to include(
            game_id:,
            white_username: white,
            status: 'created',
            move_count: 0
          )
          expect(result.state[:created_at]).to be_a(String)
        }
    end

    it 'seats black and transitions to in_progress on PlayerJoined(black)' do
      with_reactor(GamesProjector, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .and(Game::PlayerJoined, game_id:, username: black, color: 'black')
        .then { |result|
          expect(result.state[:black_username]).to eq(black)
          expect(result.state[:status]).to eq('in_progress')
        }
    end

    it 'ignores PlayerJoined for non-black colors' do
      with_reactor(GamesProjector, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .and(Game::PlayerJoined, game_id:, username: 'eve', color: 'white')
        .then { |result|
          expect(result.state[:black_username]).to be_nil
          expect(result.state[:status]).to eq('created')
        }
    end

    it 'increments move_count on each MoveMade' do
      with_reactor(GamesProjector, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .and(Game::PlayerJoined, game_id:, username: black, color: 'black')
        .and(
          Game::MoveMade,
          game_id:, username: white, color: 'white', from: 'e2', to: 'e4',
          san: 'e4', fen_after: 'fen1'
        )
        .and(
          Game::MoveMade,
          game_id:, username: black, color: 'black', from: 'e7', to: 'e5',
          san: 'e5', fen_after: 'fen2'
        )
        .then { |result|
          expect(result.state[:move_count]).to eq(2)
        }
    end

    it 'transitions to ended with reason and winner on GameEnded' do
      with_reactor(GamesProjector, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .and(Game::PlayerJoined, game_id:, username: black, color: 'black')
        .and(Game::GameEnded, game_id:, reason: 'resignation', winner: 'white')
        .then { |result|
          expect(result.state[:status]).to eq('ended')
          expect(result.state[:end_reason]).to eq('resignation')
          expect(result.state[:winner]).to eq('white')
        }
    end
  end

  describe 'sync — DB upserts' do
    it 'writes a row to the games table' do
      with_reactor(GamesProjector, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .then! { |_result|
          row = test_db[:games].where(game_id:).first
          expect(row).to include(
            game_id:,
            white_username: white,
            status: 'created',
            move_count: 0
          )
        }
    end

    it 'updates the row to in_progress when black joins' do
      with_reactor(GamesProjector, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .and(Game::PlayerJoined, game_id:, username: black, color: 'black')
        .then! { |_result|
          row = test_db[:games].where(game_id:).first
          expect(row).to include(
            status: 'in_progress',
            black_username: black
          )
        }
    end

    it 'persists move_count and end state' do
      with_reactor(GamesProjector, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .and(Game::PlayerJoined, game_id:, username: black, color: 'black')
        .and(
          Game::MoveMade,
          game_id:, username: white, color: 'white', from: 'e2', to: 'e4',
          san: 'e4', fen_after: 'fen1'
        )
        .and(Game::GameEnded, game_id:, reason: 'checkmate', winner: 'white')
        .then! { |_result|
          row = test_db[:games].where(game_id:).first
          expect(row).to include(
            status: 'ended',
            end_reason: 'checkmate',
            winner: 'white',
            move_count: 1
          )
        }
    end
  end

  describe 'auto-published Projected signal' do
    # boot.rb doesn't load app.rb (where the resolver lives), so register the
    # per-game channel here to assert the auto-injected after_sync routes
    # through Sidereal.channels.for.
    before do
      Sidereal.channels.channel_name(GamesProjector::Projected) { |m| "games.#{m.payload.game_id}" }
    end

    it 'publishes a Projected signal on the per-game channel after each batch' do
      expect(Sidereal.pubsub).to receive(:publish) do |channel, evt|
        expect(channel).to eq("games.#{game_id}")
        expect(evt).to be_a(GamesProjector::Projected)
        expect(evt.payload.game_id).to eq(game_id)
      end

      # No-block form runs Sync/AfterSync exactly once (the block form of
      # `.then!` re-runs them via compute_state, double-firing the publish).
      with_reactor(GamesProjector, game_id:)
        .given(Game::GameCreated, game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN)
        .then!([])
    end
  end

  describe 'class-level queries' do
    def project(events, partition:)
      reactor = with_reactor(GamesProjector, game_id: partition)
      events.each_with_index do |(klass, attrs), idx|
        reactor = idx.zero? ? reactor.given(klass, **attrs) : reactor.and(klass, **attrs)
      end
      reactor.then! { |_| }
    end

    let(:other_id) { 'game-2' }
    let(:closed_id) { 'game-3' }

    before do
      project(
        [[Game::GameCreated, { game_id:, white_username: white, initial_fen: ChessEngine::INITIAL_FEN }]],
        partition: game_id
      )
      project(
        [
          [Game::GameCreated, { game_id: other_id, white_username: white, initial_fen: ChessEngine::INITIAL_FEN }],
          [Game::PlayerJoined, { game_id: other_id, username: black, color: 'black' }]
        ],
        partition: other_id
      )
      project(
        [
          [Game::GameCreated, { game_id: closed_id, white_username: 'eve', initial_fen: ChessEngine::INITIAL_FEN }],
          [Game::PlayerJoined, { game_id: closed_id, username: white, color: 'black' }],
          [Game::GameEnded, { game_id: closed_id, reason: 'resignation', winner: 'black' }]
        ],
        partition: closed_id
      )
    end

    describe '.open_games' do
      it 'returns only games with status created' do
        ids = described_class.open_games.map { |r| r[:game_id] }
        expect(ids).to eq([game_id])
      end
    end

    describe '.games_for' do
      it 'returns games where the user is white or black, excluding their own open games' do
        # alice is white in `game_id` (open — excluded), white in `other_id` (in_progress — included),
        # and black in `closed_id` (ended — included).
        ids = described_class.games_for(white).map { |r| r[:game_id] }
        expect(ids).to contain_exactly(other_id, closed_id)
      end

      it 'orders results newest-first' do
        rows = described_class.games_for(white)
        timestamps = rows.map { |r| r[:created_at] }
        expect(timestamps).to eq(timestamps.sort.reverse)
      end

      it 'returns an empty array when the user has no games' do
        expect(described_class.games_for('nobody')).to eq([])
      end
    end

    describe '.on_reset' do
      it 'deletes all rows from the games table' do
        expect(test_db[:games].count).to be > 0
        described_class.on_reset
        expect(test_db[:games].count).to eq(0)
      end
    end
  end
end
