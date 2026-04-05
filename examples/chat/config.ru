require_relative "app"

use Rack::Static, urls: ['/css', '/js'], root: "public"

run ChatApp
