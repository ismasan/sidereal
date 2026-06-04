#!/usr/bin/env falcon-host
# frozen_string_literal: true

require 'sourced'
require 'sidereal'
require 'sidereal/falcon/environment'

service "sidereal-sourced-donations" do
  include Sidereal::Falcon::Environment
  include Falcon::Environment::Rackup

  url "http://localhost:9295"
  count 1
end
