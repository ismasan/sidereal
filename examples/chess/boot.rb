# frozen_string_literal: true

require 'sidereal'
require 'sidereal/integrations/sourced'

DB_PATH = File.expand_path('storage/chess.db', __dir__)

# Components first: nothing is built until the process starts, so the files
# can declare in any order, and app classes can inject them.
Dir[File.join(__dir__, 'config/components/*.rb')].sort.each { |f| require f }

# Cross-process pubsub + leader election (unix socket + file lock under
# ./storage), then Sourced's store and runtime, on the 'db' component: opened
# in each worker when it starts, never while this file loads (SQLite
# connections aren't fork-safe).
Sidereal.config.use_file_system!
Sidereal.config.use Sidereal::Integrations::Sourced, db: 'db'

# Demo retry policy: retry a failing command a few times before dead-lettering
# (drives the amber retry toasts). The integration reports retries and
# failures from whatever strategy is implemented here.
Sidereal.config.config!('sourced.error_strategy') do
  Sourced::ErrorStrategy.new.retry(times: 3, after: 1)
end

require_relative 'domain/chess_engine'
require_relative 'domain/game'
require_relative 'domain/game_view'
require_relative 'domain/games_projector'

Sourced.register(Game)
Sourced.register(GamesProjector)

# Optional logger subscriber — preserves the previous server-side error
# logging and demonstrates the subscriber API. Array(...) guards against a
# backtrace-less exception.
Sidereal.exceptions.on_failure do |report|
  Sourced.logger.error("#{report.exception.class}: #{report.exception.message}")
  Sourced.logger.error(Array(report.exception.backtrace).join("\n"))
end
