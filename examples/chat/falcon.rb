#!/usr/bin/env falcon-host
# frozen_string_literal: true

require_relative 'app'
require 'sidereal/falcon/environment'

# Set PORT in the environment to launch on a different port. This lets you
# run multiple master processes in separate terminals all backed by the same
# tmp/sidereal-pubsub.sock and tmp/sidereal-store/ — exercising the
# cross-process FileSystem store + Unix pubsub:
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
