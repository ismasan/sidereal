require 'sourced/ui/dashboard'
require_relative 'boot'
require_relative 'web/app'

Sourced::UI::Dashboard.configure do |config|
  config.header_links([
    { label: 'back to app', href: '/', url: false }
  ])
end

map '/sourced' do
  run Sourced::UI::Dashboard
end

map '/' do
  run App
end
