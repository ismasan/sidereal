# frozen_string_literal: true

# Cross-partition read model that powers the home-page lobby.
# One row per game, upserted as the game's events arrive. Mirrors the
# CampaignsProjector pattern in examples/sourced_donations/.
class GamesProjector < Sourced::Projector::StateStored
  consumer_group 'games_projector'
  partition_by :game_id

  state do |values|
    db = Sourced.store.db
    db[:games].where(game_id: values[:game_id]).first ||
      {
        game_id: nil,
        white_username: nil,
        black_username: nil,
        status: nil,
        end_reason: nil,
        winner: nil,
        move_count: 0,
        created_at: nil
      }
  end

  evolve(Game::GameCreated) do |s, e|
    s[:game_id] = e.payload.game_id
    s[:white_username] = e.payload.white_username
    s[:status] = 'created'
    s[:created_at] = e.created_at.iso8601
  end

  evolve(Game::PlayerJoined) do |s, e|
    if e.payload.color == 'black'
      s[:black_username] = e.payload.username
      s[:status] = 'in_progress'
    end
  end

  evolve(Game::MoveMade) do |s, _e|
    s[:move_count] = s[:move_count].to_i + 1
  end

  evolve(Game::GameEnded) do |s, e|
    s[:status] = 'ended'
    s[:end_reason] = e.payload.reason
    s[:winner] = e.payload.winner
  end

  sync do |state:, **|
    next unless state[:game_id]

    Sourced.store.db[:games].insert_conflict(:replace).insert(state)
  end

  # A `Projected` signal (attribute: game_id) is auto-generated from
  # `partition_by` and published after each committed batch by
  # Sidereal::Integrations::Sourced — routed via Sidereal.channels.for.

  def self.on_reset
    Sourced.store.db[:games].delete
  end

  # ---- Class-level queries ----

  def self.open_games
    Sourced.store.db[:games].where(status: 'created').order(Sequel.desc(:created_at)).all
  end

  # Games where +username+ is white or black, EXCLUDING open games where
  # they are white (those already appear under "Open games"). Newest first.
  def self.games_for(username)
    Sourced.store.db[:games]
      .where(Sequel.|({ white_username: username }, { black_username: username }))
      .exclude(status: 'created', white_username: username)
      .order(Sequel.desc(:created_at))
      .all
  end
end
