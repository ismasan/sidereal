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

# Each forked Falcon worker loads this file in its own process, so the
# Sourced store and reactors below are established fresh per worker (SQLite
# connections aren't fork-safe, but nothing is inherited across the fork).
Sourced.configure do |config|
  config.store = Sequel.sqlite(DB_PATH) unless ENV['TEST']
end

Sourced.register(Donation)
Sourced.register(Campaign)
Sourced.register(CampaignsProjector)

# Skip the Sidereal runtime bridge in TEST — specs drive deciders directly.
unless ENV['TEST']
  Sidereal.configure do |c|
    # Cross-process pubsub + leader election (unix socket + file lock under
    # ./storage), so SSE updates fan out to subscribers on every worker via
    # one elected broker — required for count > 1.
    c.use_file_system!
    # ...but keep Sourced's SQLite store + dispatcher, not the FS store. One call
    # wires both (+ the error bridge). Sourced is already configured above, so no
    # `store:` arg. The dispatcher also auto-registers any Sidereal Commanders
    # with Sourced before starting the runtime (none in this demo yet).
    c.use Sidereal::Integrations::Sourced
  end
end

# Optional logger subscriber — preserves the previous server-side error
# logging and demonstrates the subscriber API. Added once before
# Sidereal::Host#start locks the exceptions registry. Array(...) guards
# against a backtrace-less exception.
Sidereal.exceptions.on_failure do |report|
  Sourced.config.logger.error("#{report.exception.class}: #{report.exception.message}")
  Sourced.config.logger.error(Array(report.exception.backtrace).join("\n"))
end
