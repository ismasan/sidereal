# frozen_string_literal: true

require 'fileutils'
require 'sequel'
require 'sqlite3'

# The app's SQLite database: Sourced's event store (see boot.rb) and the games
# read model share it. Each worker opens its own connection at boot and
# disconnects it on shutdown. In TEST it is a fresh in-memory database.
Sidereal.dependencies.register!('db') do
  if ENV['TEST']
    Sequel.sqlite
  else
    FileUtils.mkdir_p(File.dirname(DB_PATH))
    Sequel.sqlite(DB_PATH)
  end
end.teardown do |db|
  db.disconnect
end
