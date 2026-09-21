#!/usr/bin/env falcon-host
# frozen_string_literal: true

require_relative 'config/env'
require 'sourced'
require 'sidereal'
require 'sidereal/falcon/environment'

# Bind defaults to localhost:9297; override from the environment, e.g.
#   PORT=8080 bundle exec falcon host falcon.rb
#   HOST=0.0.0.0 PORT=80 bundle exec falcon host falcon.rb
HOST = ENV.fetch('HOST', 'localhost')
PORT = ENV.fetch('PORT', '9297')
# One process, because the event store is SQLite and every Falcon worker runs
# its own Sourced dispatcher: more processes means more concurrent writers to
# one file, which at boot shows up as `database is locked`. Raise COUNT when
# the store can take it — the Unix-socket pubsub (see boot.rb) already carries
# SSE updates across processes, so nothing else needs to change. Computed out
# here: the service block is instance_eval'd on a builder where Kernel#Integer
# isn't available.
COUNT = Integer(ENV.fetch('COUNT', '1'))

service "sidereal-moderator" do
  include Sidereal::Falcon::Environment
  include Falcon::Environment::Rackup

  url "http://#{HOST}:#{PORT}"
  count COUNT
end
