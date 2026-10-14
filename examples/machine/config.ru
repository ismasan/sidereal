# frozen_string_literal: true

require_relative 'boot'
require 'sourced/ui/dashboard'

# Sourced's dashboard: the message log, consumer groups and causation trees.
Sourced::UI::Dashboard.configure do |config|
  config.header_links([
    { label: 'back to app', href: '/', url: false }
  ])
end

map '/sourced' do
  run Sourced::UI::Dashboard
end

map '/' do
  use Rack::Static, urls: ['/css'], root: 'web/public'
  run App
end
