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
# Worker processes. The Sourced runtime (dispatcher, reactors, the classifier)
# runs on the elected leader only (see boot.rb); the other workers serve pages
# and append commands, so there is still one set of SQLite writers however many
# processes serve HTTP. The Unix-socket pubsub carries SSE updates across all
# of them. Computed out here: the service block is instance_eval'd on a builder
# where Kernel#Integer isn't available.
COUNT = Integer(ENV.fetch('COUNT', '3'))

service "sidereal-moderator" do
  include Sidereal::Falcon::Environment
  include Falcon::Environment::Rackup

  url "http://#{HOST}:#{PORT}"
  count COUNT
end
