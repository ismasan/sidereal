# frozen_string_literal: true

require 'fileutils'
require 'sequel'
require 'sqlite3'

# The app's database, as two components: `db.filepath` is where the SQLite file
# lives, and `db` is the connection to it. Each process opens its own when it
# starts and disconnects it on shutdown — a SQLite connection can't be shared
# across a fork, so nothing is opened while this file loads.
#
# Classes ask for the connection with `dep :db`, and `bin/sid db migrations run`
# migrates it.
#
# The last implementation of a key wins, so either one can be replaced — here,
# or from another file in config/components/. To keep the file somewhere else:
#
#   Sidereal.config.config!('db.filepath') { ENV.fetch('DATABASE_FILE') }
#
# Or source the value from the ENV with a one-liner:
# 
#   Sidereal.config.env('DATABASE_FILE' => 'db.filepath')
#
# Or to use another database entirely, re-implement `db` and ignore the path:
#
#   Sidereal.config.component!('db') do
#     build { Sequel.connect(ENV.fetch('DATABASE_URL')) }
#     teardown(&:disconnect)
#   end
#
# The path is relative to the app's root, which is where `falcon host` and
# `bin/sid` both run from.
Sidereal.config.tap do |c|
  c.declare('db.filepath', Sidereal::Types::String) { 'storage/db.db' }
  c.declare('db', Sequel::Database)
  c.component!('db', ['db.filepath']) do
    build do |filepath|
      FileUtils.mkdir_p(File.dirname(filepath))
      Sequel.sqlite(filepath)
    end
    teardown(&:disconnect)
  end
end
