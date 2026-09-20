# frozen_string_literal: true

require 'fileutils'
require 'sequel'
require 'sqlite3'
require 'sidereal'
require 'sidereal/integrations/sourced'

DB_PATH = File.expand_path('storage/moderator.db', __dir__)
FileUtils.mkdir_p(File.dirname(DB_PATH))

require_relative 'domain/subjects'
require_relative 'domain/comment'
require_relative 'domain/comments_projector'

# Each forked Falcon worker loads this file in its own process, so the
# Sourced store and reactors are established fresh per worker (SQLite
# connections aren't fork-safe, but nothing is inherited across the fork).
Sourced.configure do |config|
  config.store = Sequel.sqlite(DB_PATH) unless ENV['TEST']
end

Sourced.register(Comment)
Sourced.register(CommentsProjector)

# Only bridge Sidereal to the Sourced store at runtime — in TEST mode there's
# no real store and the unit specs drive the decider directly.
unless ENV['TEST']
  Sidereal.configure do |c|
    # Cross-process pubsub + leader election (unix socket + file lock under
    # ./storage) so SSE updates fan out to every worker — required for
    # COUNT > 1 in falcon.rb.
    c.use_file_system!
    # Sourced's SQLite store + dispatcher instead of the FS store, plus the
    # error bridge that turns Sourced retries/failures into UI toasts.
    c.use Sidereal::Integrations::Sourced
  end
end

# Server-side log of terminal failures (e.g. an optimistic-lock conflict
# when two moderators race on one comment). Registered before
# Sidereal::Host#start locks the exceptions registry.
Sidereal.exceptions.on_failure do |report|
  Sourced.config.logger.error("#{report.exception.class}: #{report.exception.message}")
  Sourced.config.logger.error(Array(report.exception.backtrace).join("\n"))
end
