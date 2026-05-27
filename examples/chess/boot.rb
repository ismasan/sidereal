# frozen_string_literal: true

require 'fileutils'
require 'sequel'
require 'sqlite3'
require 'sourced'
require 'sidereal'

DB_PATH = File.expand_path('storage/chess.db', __dir__)
FileUtils.mkdir_p(File.dirname(DB_PATH))

require_relative 'domain/chess_engine'
require_relative 'domain/game'
require_relative 'domain/game_view'
require_relative 'domain/games_projector'

# Wire everything inside Sourced.configure so it is re-run after Falcon forks
# (SQLite connections are not fork-safe).
Sourced.configure do |config|
  config.store = Sequel.sqlite(DB_PATH) unless ENV['TEST']
  config.error_strategy do |s|
    s.retry(times: 1, after: 1)

    s.on_fail do |exception, _message|
      Sourced.config.logger.error("#{exception.class}: #{exception.message}")
      Sourced.config.logger.error(exception.backtrace.join("\n"))
    end
  end

  # Only bridge Sidereal to the Sourced store at runtime — in TEST mode
  # there's no real store and the unit specs drive the decider directly.
  if config.store
    Sidereal.configure do |c|
      c.store      = config.store
      c.dispatcher = Sourced::Dispatcher
    end
  end

  Sourced.register(Game)
  Sourced.register(GamesProjector)
end
