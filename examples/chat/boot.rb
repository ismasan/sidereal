# frozen_string_literal: true

require 'fileutils'
require 'sequel'
require 'sqlite3'
require 'sidereal'
require 'sidereal/integrations/sourced'

DB_PATH = File.expand_path('tmp/chat.db', __dir__)
FileUtils.mkdir_p(File.dirname(DB_PATH))

# Each forked Falcon worker loads this file in its own process, so the Sourced
# SQLite store below is established fresh per worker (SQLite connections aren't
# fork-safe, but nothing is inherited across the fork).
Sourced.configure do |config|
  config.store = Sequel.sqlite(DB_PATH) unless ENV['TEST']
  # Poll every 0.5s so cross-process dispatches (e.g. `Sidereal.dispatch!` from a
  # console) are picked up quickly. SQLite has no LISTEN/NOTIFY, so out-of-process
  # appends rely on this catch-up poll rather than the in-process notifier.
  config.catchup_interval = 0.5
end

# This demo has no Sourced deciders/projectors — only Sidereal Commanders
# (defined in app.rb). The Sourced integration's dispatcher auto-registers
# those Commanders with Sourced before starting the runtime, so there's
# nothing to Sourced.register here.

Sidereal.configure do |c|
  c.workers = 3
  # Cross-process pubsub + leader election (unix socket + file lock under
  # tmp/), so SSE updates fan out to subscribers on every worker via one
  # elected broker — required for count > 1.
  c.use_file_system!(dir: 'tmp')
  # ...but keep Sourced's SQLite store + dispatcher, not the FS store. One call
  # wires both (+ the error bridge). Sourced is already configured above, so no
  # `store:` arg.
  c.use Sidereal::Integrations::Sourced
end
