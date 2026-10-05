# frozen_string_literal: true

require 'fileutils'
require 'sequel'
require 'sqlite3'
require 'sidereal'
require 'sidereal/integrations/sourced'

DB_PATH = File.expand_path('tmp/chat.db', __dir__)
FileUtils.mkdir_p(File.dirname(DB_PATH))

# The chat log app.rb appends every message to, one JSON object per line.
# Relative to the working directory, so `falcon host` and `rake` agree on it
# when run from this directory.
MESSAGES_FILE = 'chat_messages.jsonl'

# The Sourced store's SQLite database. Each forked Falcon worker opens its own
# connection when it starts (SQLite connections aren't fork-safe), and
# disconnects it when it stops.
Sidereal.config.declare('db', Sequel::Database)
Sidereal.config.component!('db') do
  build { Sequel.sqlite(DB_PATH) }
  teardown(&:disconnect)
end

# Cross-process pubsub + leader election (unix socket + file lock under
# tmp/), so SSE updates fan out to subscribers on every worker via one
# elected broker — required for count > 1.
Sidereal.config.use_file_system!(dir: 'tmp')

# ...but keep commands in Sourced's SQLite store, on the 'db' component, and
# run them on Sourced's runtime (+ the error bridge).
#
# This demo has no Sourced deciders/projectors — only Sidereal Commanders
# (defined in app.rb), which the integration registers with Sourced when the
# app boots, so there's nothing to Sourced.register here.
Sidereal.config.use Sidereal::Integrations::Sourced, db: 'db'

# Poll every 0.5s so cross-process dispatches (e.g. `rake db:seed`) are picked
# up quickly. SQLite has no LISTEN/NOTIFY, so appends from a process without
# the unix-socket pubsub rely on this catch-up poll.
Sidereal.config.config!('sourced.workers.catchup_interval') { 0.5 }
