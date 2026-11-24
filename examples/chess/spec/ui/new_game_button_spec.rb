# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NewGameButton do
  # Handles the commands NewGameButton declares as ChessApp does, in a small
  # app that subclasses it, with its session and before_command. What the
  # handler dispatches is recorded, not stored, so the Game decider doesn't
  # run.
  subject(:harness) { Sidereal::Testing::Harness.new(described_class, app: ChessApp) }

  let(:game_id) { SecureRandom.uuid }

  it 'refuses to start a game without a logged-in player' do
    result = harness.handle(Game::CreateGame, { game_id: })

    expect(result.status).to eq(401)
    expect(result.body).to eq('login required')
    expect(result.dispatched).to be_empty
  end

  it "starts a game for the logged-in player, as White, and takes them to it" do
    result = harness.handle(Game::CreateGame, { game_id: }, session: { username: 'alice' })

    expect(result.dispatched.map(&:class)).to eq([Game::CreateGame])
    expect(result.dispatched.first.payload.to_h).to include(game_id:, white_username: 'alice')
    expect(result.elements.join).to include("/games/#{game_id}")
  end
end
