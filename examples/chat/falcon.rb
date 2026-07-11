#!/usr/bin/env falcon-host
# frozen_string_literal: true

require 'sidereal'
require 'sidereal/falcon/environment'

# Lazy-load: the controller doesn't require the app — each forked worker loads
# config.ru (→ boot.rb → app.rb) in its own process, so the Sourced SQLite
# connection is established fresh per worker (see boot.rb).
#
# Set PORT in the environment to launch on a different port. This lets you run
# multiple master processes in separate terminals all backed by the same
# tmp/chat.db (Sourced store) and tmp/pubsub.sock (Unix pubsub) — configured in
# boot.rb via the Sourced integration + c.use_file_system!(dir: 'tmp'):
#
#   bundle exec falcon-host falcon.rb              # → http://localhost:9293
#   PORT=9294 bundle exec falcon-host falcon.rb    # → http://localhost:9294
#
PORT = ENV.fetch('PORT', '9293')

service "sidereal-chat-#{PORT}" do
  include Sidereal::Falcon::Environment
  include Falcon::Environment::Rackup

  url "http://localhost:#{PORT}"
  count 3
end
