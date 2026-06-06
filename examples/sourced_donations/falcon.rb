#!/usr/bin/env falcon-host
# frozen_string_literal: true

require 'sidereal'
require 'sidereal/falcon/environment'

# Bind defaults to localhost:9295; override from the environment, e.g.
#   PORT=8080 bundle exec falcon host falcon.rb
#   HOST=0.0.0.0 PORT=80 bundle exec falcon host falcon.rb
HOST = ENV.fetch('HOST', 'localhost')
PORT = ENV.fetch('PORT', '9295')
# Multiple workers — the Unix-socket pubsub (see boot.rb) lets SSE updates
# cross process boundaries. Override with COUNT. Compute it out here: the
# service block is instance_eval'd on a builder where Kernel#Integer isn't
# available (a bare Integer(...) inside the block resolves to a no-op symbol).
COUNT = Integer(ENV.fetch('COUNT', '3'))

service "sidereal-sourced-donations" do
  include Sidereal::Falcon::Environment
  include Falcon::Environment::Rackup

  url "http://#{HOST}:#{PORT}"
  count COUNT
end
