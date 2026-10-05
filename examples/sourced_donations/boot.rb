# frozen_string_literal: true

require 'fileutils'
require 'sequel'
require 'sqlite3'
require 'sidereal'
require 'sidereal/integrations/sourced'

DB_PATH = File.expand_path('storage/donations.db', __dir__)
FileUtils.mkdir_p(File.dirname(DB_PATH))

require_relative 'domain/campaign'
require_relative 'domain/donation'
require_relative 'domain/campaigns_projector'
require_relative 'domain/donation_view'

# The app's SQLite database, where Sourced keeps its events and the
# CampaignsProjector its read model. Each forked Falcon worker opens its own
# connection when it starts (SQLite connections aren't fork-safe), and
# disconnects it when it stops. In TEST it is a fresh in-memory database.
Sidereal.config.declare('db', Sequel::Database)
Sidereal.config.component!('db') do
  build { ENV['TEST'] ? Sequel.sqlite : Sequel.sqlite(DB_PATH) }
  teardown(&:disconnect)
end

# Cross-process pubsub + leader election (unix socket + file lock under
# ./storage), so SSE updates fan out to subscribers on every worker via one
# elected broker — required for count > 1.
Sidereal.use_file_system!

# ...but keep commands in Sourced's SQLite store, on the 'db' component, and
# run Sourced's runtime (+ the error bridge). The runtime also runs any
# Sidereal Commanders (none in this demo yet).
#
# This also pins the Sourced runtime to the elected leader
# (sidereal.runner.process = :leader): with COUNT > 1 the other workers
# only serve pages and append commands, so SQLite sees one writer for handler
# and projection work. Appends on any worker wake the leader through the
# unix-socket pubsub.
Sidereal.use Sidereal::Integrations::Sourced, db: 'db'

Sourced.register(Donation)
Sourced.register(Campaign)
Sourced.register(CampaignsProjector)

# Optional logger subscriber — preserves the previous server-side error
# logging and demonstrates the subscriber API. Added once before
# Sidereal::Host#start locks the exceptions registry. Array(...) guards
# against a backtrace-less exception.
Sidereal.exceptions.on_failure do |report|
  Sourced.logger.error("#{report.exception.class}: #{report.exception.message}")
  Sourced.logger.error(Array(report.exception.backtrace).join("\n"))
end
