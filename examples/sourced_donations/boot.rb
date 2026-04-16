# frozen_string_literal: true

require 'fileutils'
require 'sequel'
require 'sqlite3'
require 'sourced'
require 'sidereal'

DB_PATH = File.expand_path('storage/donations.db', __dir__)
FileUtils.mkdir_p(File.dirname(DB_PATH))

require_relative 'domain/donation'
require_relative 'domain/campaign'
require_relative 'domain/campaigns_projector'
require_relative 'domain/donation_view'

# Wire everything inside Sourced.configure so it is re-run after Falcon forks
# (SQLite connections are not fork-safe — Sourced calls setup! in the worker
# process to rebuild the store, and we need Sidereal + reactor registration
# to follow along).
Sourced.configure do |config|
  config.store = Sequel.sqlite(DB_PATH) unless ENV['TEST']
  config.error_strategy do |s|
    s.retry(times: 1, after: 1)

    s.on_fail do |exception, _message|
      Sourced.config.logger.error("#{exception.class}: #{exception.message}")
      Sourced.config.logger.error(exception.backtrace.join("\n"))
    end
  end

  Sidereal.configure do |c|
    c.store      = config.store
    c.dispatcher = Sourced::Dispatcher
  end

  Sourced.register(Donation)
  Sourced.register(Campaign)
  Sourced.register(CampaignsProjector)
end
