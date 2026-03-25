#!/usr/bin/env falcon-host
# frozen_string_literal: true

require_relative 'app'
require 'sidereal/falcon/environment'

service "sidereal-chat" do
  include Sidereal::Falcon::Environment
  include Falcon::Environment::Rackup

  url "http://localhost:9293"
  count 1
end
