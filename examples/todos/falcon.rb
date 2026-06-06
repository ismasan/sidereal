#!/usr/bin/env falcon-host
# frozen_string_literal: true

require_relative 'app'
require 'sidereal/falcon/environment'

# Bind defaults to localhost:9292; override from the environment, e.g.
#   PORT=8080 bundle exec falcon host falcon.rb
#   HOST=0.0.0.0 PORT=80 bundle exec falcon host falcon.rb
HOST = ENV.fetch('HOST', 'localhost')
PORT = ENV.fetch('PORT', '9292')

service "sidereal-app" do
  include Sidereal::Falcon::Environment
  include Falcon::Environment::Rackup

  url "http://#{HOST}:#{PORT}"
  count 1
end
