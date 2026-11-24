# frozen_string_literal: true

# How layouts link the app's assets (see web/app.rb). :single links each
# stylesheet and script, and notices when a file changes, so an edit shows
# without a restart. :combined links one bundle of the stylesheets and one of
# the scripts, and digests each file once. Either serves both kinds of URL.
# Here it follows APP_ENV (or RACK_ENV): bundles in production.
Sidereal.config.config!('sidereal.assets.mode') do
  Sidereal.environment == 'production' ? :combined : :single
end

# A host asset URLs start with, such as a CDN that fetches them from the app:
#
#   Sidereal.config.config!('sidereal.assets.host') { ENV['ASSETS_HOST'] }

# Live reload: when a stylesheet, script or image changes, open pages update
# without a restart. A stylesheet is swapped in place, an image re-renders the
# page, and a script reloads it. On in development.
Sidereal.config.config!('sidereal.assets.live_reload') do
  Sidereal.environment == 'development'
end
