# frozen_string_literal: true

require_relative 'config/env'
require 'fileutils'
require 'sequel'
require 'sqlite3'
require 'sidereal'
require 'sidereal/integrations/sourced'

DB_PATH = File.expand_path(ENV.fetch('DATABASE_PATH', 'storage/moderator.db'), __dir__)

require_relative 'domain/subjects'
require_relative 'domain/comment'
require_relative 'domain/classifier'
require_relative 'domain/comments_projector'

# The app's SQLite database: Sourced's event store and the comments read model
# share it. Each forked Falcon worker opens its own connection when it starts
# (SQLite connections aren't fork-safe) and disconnects it when it stops. In
# TEST it is a fresh in-memory database.
#
# The Sourced dispatcher runs on the elected leader only, so there is one
# dispatcher however many Falcon processes serve HTTP, but Sourced's
# `fiber_concurrency` extension still gives each of its worker fibers its own
# connection — a handful of writers against one file, plus the appends coming
# in from the other workers' HTTP requests.
#
# Sourced's store already begins its own writes as IMMEDIATE. Setting the mode
# on the connection covers the transactions that don't go through that helper,
# and a longer `timeout` gives a writer more room to wait for the lock rather
# than raising `database is locked`. Sequel applies `timeout` to every
# connection it opens, unlike a bare `PRAGMA busy_timeout`, which only reaches
# whichever pooled connection ran it.
Sidereal.config.declare('db', Sequel::Database)
Sidereal.config.component!('db') do
  build do
    if ENV['TEST']
      Sequel.sqlite
    else
      FileUtils.mkdir_p(File.dirname(DB_PATH))
      Sequel.sqlite(DB_PATH, timeout: 15_000).tap { |db| db.transaction_mode = :immediate }
    end
  end
  teardown(&:disconnect)
end

# Cross-process pubsub + leader election (unix socket + file lock under
# ./storage) so SSE updates fan out to every worker — required for COUNT > 1
# in falcon.rb.
Sidereal.config.use_file_system!

# Sourced's SQLite store + dispatcher instead of the FS store, on the 'db'
# component, plus the error bridge that turns Sourced retries/failures into UI
# toasts. Also pins the dispatcher to the elected leader, so only one process
# runs reactors against SQLite; the rest append commands and serve pages.
Sidereal.config.use Sidereal::Integrations::Sourced, db: 'db'

# Worker fibers are shared by every consumer group, and a fiber is occupied
# for the whole of a reaction — including the Classifier's model call, which
# takes the best part of a second. At the default of 2 both fibers sit in
# model calls and nothing is left to apply the verdicts they produce, so
# comments cross the board in one late batch instead of moving one by one.
# Size this by how much slow work runs concurrently, not by CPU.
#
# SLOWMO=<seconds> slows everything down instead: two messages per claim, and
# a pause after each projector commit (see CommentsProjector), so a rebuild can
# be watched land on the board one event at a time.
if ENV['SLOWMO']
  Sidereal.config.config!('sourced.workers.count') { 6 }
  Sidereal.config.config!('sourced.workers.batch_size') { 2 }
else
  Sidereal.config.config!('sourced.workers.count') { 30 }
end

Sourced.register(Comment)
Sourced.register(CommentsProjector)

if ENV['TYPESAFE_API_KEY']
  Sourced.register(Classifier)
else
  Console.warn "No TYPESAFE_API_KEY in the environment. Auto classifier not registered."
end

# The classifier keeps its own retry policy (see domain/classifier.rb), so it
# needs the Sidereal bridge wired onto that strategy too — the integration
# only wires the global one. This is what turns a rate-limited model call into
# an amber retry toast on the board. The unit specs call the strategy directly.
unless ENV['TEST']
  Classifier::RETRY_STRATEGY.on_retry Sidereal.exceptions
  Classifier::RETRY_STRATEGY.on_fail Sidereal.exceptions
end

# Server-side log of terminal failures (e.g. an optimistic-lock conflict
# when two moderators race on one comment). Registered before
# Sidereal::Host#start locks the exceptions registry.
Sidereal.exceptions.on_failure do |report|
  Sourced.logger.error("#{report.exception.class}: #{report.exception.message}")
  Sourced.logger.error(Array(report.exception.backtrace).join("\n"))
end
