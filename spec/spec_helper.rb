# frozen_string_literal: true

require 'debug'
require 'async'
require 'console'
require 'logger'
require "sidereal"

# Silence Console logs during tests — error/warn output from intentional
# failure-path tests (dispatcher handler errors, publish errors) drowns
# out the rspec progress otherwise. Set CONSOLE_LEVEL=debug to re-enable.
Console.logger.level = Logger::FATAL unless ENV['CONSOLE_LEVEL']

module SiderealSpecHelpers
  # Drain `count` messages from a store and return them.
  # `claim_next` now loops indefinitely, so tests that just want to
  # peek at what was appended use this to spin a consumer fiber
  # that stops once it has the expected number of messages.
  def claim_messages(store, count)
    claimed = []
    Sync do |task|
      store.start(task)
      consumer = task.async do
        store.claim_next { |m| claimed << m }
      end
      task.async do
        loop do
          break if claimed.size >= count
          task.yield
        end
        consumer.stop
      end.wait
    end
    claimed
  end

  def claim_one(store) = claim_messages(store, 1).first
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include SiderealSpecHelpers

  config.before(:each) { Sidereal.reset_registry! }
end
