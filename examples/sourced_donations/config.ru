# require 'sourced/ui/dashboard'
require_relative 'boot'
require_relative 'app'

# Sourced::UI::Dashboard.configure do |config|
#   config.header_links([
#     { label: 'back to app', href: '/', url: false }
#   ])
# end
#
# map '/sourced' do
#   run Sourced::UI::Dashboard
# end

map '/' do
  use Rack::Static, urls: ['/css', '/js'], root: 'public'
  run DonationsApp
end
