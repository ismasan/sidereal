# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in sidereal.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

gem "rack-test", "~> 2.2"
gem 'debug'

# Apps bring their own host, so falcon is not a gem dependency; the specs for
# lib/sidereal/falcon need it to load.
gem 'falcon'

group :development do
  gem 'docco', github: 'ismasan/docco'
  gem 'sourced', path: '../sourced'
  # Local sourced tracks the local plumb; the published 0.2.0.beta.1 gem lacks
  # the Codec#register/#encode/#decode instance API sourced's MessageCodec uses.
  gem 'plumb', path: '../plumb'
end
