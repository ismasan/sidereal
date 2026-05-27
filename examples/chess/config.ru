require_relative 'boot'
require_relative 'app'
require 'sourced/ui/dashboard'

Sourced::UI::Dashboard.configure do |config|
  config.header_links([
    { label: 'back to app', href: '/', url: false }
  ])
end

map '/sourced' do
  run Sourced::UI::Dashboard
end

map '/' do
  use Rack::Static, urls: ['/css'], root: 'public'
  run ChessApp
end
