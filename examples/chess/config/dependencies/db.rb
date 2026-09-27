# frozen_string_literal: true

# The app's SQLite database: Sourced's event store and the games read model
# share it. A singleton, so Sidereal::Host builds it once per worker process at
# boot and disconnects it on shutdown. In TEST it is a fresh in-memory database.
Sidereal.dependencies.register!('db') do
  if ENV['TEST']
    Sequel.sqlite
  else
    FileUtils.mkdir_p(File.dirname(DB_PATH))
    Sequel.sqlite(DB_PATH)
  end
end.stop do |db|
  db.disconnect
end
