require_relative "app"

use Rack::Static, urls: ["/css"], root: "public"

run DonationsApp
