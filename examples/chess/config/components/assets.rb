# frozen_string_literal: true

# Layouts link each stylesheet and script, and open pages update when one
# changes, in development. In production they link one bundle of each type.
Sidereal.config.config!('sidereal.assets.mode') do
  Sidereal.environment == 'production' ? :combined : :single
end
Sidereal.config.config!('sidereal.assets.live_reload') do
  Sidereal.environment == 'development'
end
