# frozen_string_literal: true

require 'fileutils'
require 'sequel'
require 'sqlite3'
require 'sidereal'
require 'sidereal/integrations/sourced'

DB_PATH = File.expand_path('storage/chess.db', __dir__)
FileUtils.mkdir_p(File.dirname(DB_PATH))

require_relative 'domain/chess_engine'
require_relative 'domain/game'
require_relative 'domain/game_view'
require_relative 'domain/games_projector'

# Demo retry policy: retry a failing command a few times before dead-lettering
# (drives the amber retry toasts). Mutate the strategy in place rather than
# replacing it via a block — the integration above registered the
# Sidereal.exceptions bridge on this same strategy.
Sourced.config.error_strategy.retry(times: 3, after: 1)

# Each forked Falcon worker loads this file in its own process, so the
# Sourced store and reactors are established fresh per worker (SQLite
# connections aren't fork-safe, but nothing is inherited across the fork).
Sourced.configure do |config|
  config.store = Sequel.sqlite(DB_PATH) unless ENV['TEST']
end

Sourced.register(Game)
Sourced.register(GamesProjector)

# Only bridge Sidereal to the Sourced store at runtime — in TEST mode there's
# no real store and the unit specs drive the decider directly.
unless ENV['TEST']
  Sidereal.configure do |c|
    c.use_file_system!
    c.use Sidereal::Integrations::Sourced
  end
end

# Optional logger subscriber — preserves the previous server-side error
# logging and demonstrates the subscriber API. Array(...) guards against a
# backtrace-less exception.
Sidereal.exceptions.on_failure do |report|
  Sourced.config.logger.error("#{report.exception.class}: #{report.exception.message}")
  Sourced.config.logger.error(Array(report.exception.backtrace).join("\n"))
end
