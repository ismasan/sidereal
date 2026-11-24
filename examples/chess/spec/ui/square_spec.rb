# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Square do
  subject(:harness) { Sidereal::Testing::Harness.new(Square, app: ChessApp) }

  let(:game_id) { SecureRandom.uuid }

  # Sourced's tables, in the in-memory database the specs use, and a game with
  # both players seated, White to move.
  before do
    Sourced.store.install!
    Sourced.store.append([
      Game::GameCreated.new(payload: { game_id:, white_username: 'alice', initial_fen: ChessEngine::INITIAL_FEN }),
      Game::PlayerJoined.new(payload: { game_id:, username: 'bob', color: 'black' })
    ])
  end

  describe Square::SelectSource do
    it "re-renders the game with the piece selected and its moves as targets, for the player to move" do
      result = harness.handle(Square::SelectSource, { game_id:, coord: 'e2' }, session: { username: 'alice' })

      expect(result.dispatched).to be_empty
      board = result.elements.join
      expect(board).to match(/class="[^"]*selected[^"]*"[^>]*data-coord="e2"/)
      expect(board.scan(/square--valid-target[^"]*"[^>]*data-coord="(\w\d)"/).flatten).to contain_exactly('e3', 'e4')
    end
  end

  describe Game::MakeMove do
    it 'dispatches the move to the Game decider, as the logged-in player' do
      result = harness.handle(Game::MakeMove, { game_id:, from: 'e2', to: 'e4' }, session: { username: 'alice' })

      expect(result.status).to eq(200)
      expect(result.dispatched.map(&:class)).to eq([Game::MakeMove])
      expect(result.dispatched.first.payload.to_h).to include(from: 'e2', to: 'e4', username: 'alice')
    end
  end
end
