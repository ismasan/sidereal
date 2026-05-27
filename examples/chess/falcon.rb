#!/usr/bin/env falcon-host
# frozen_string_literal: true

require 'sourced'
require 'sourced/falcon'

service "sidereal-chess" do
  include Sourced::Falcon::Environment
  include Falcon::Environment::Rackup

  url "http://localhost:9296"
  count 1
end
