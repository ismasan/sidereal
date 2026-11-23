# frozen_string_literal: true

# The app's master secret. Sidereal derives a key for each use of it, with
# `Sidereal.secrets.derive('<purpose>')`: the signer it signs the URLs of
# pages' live updates with, and the session cookie's key, in web/app.rb. So
# one secret serves them all, and a key for one purpose can't stand in for
# another's.
#
# Here it's SIDEREAL_SECRET, or else the one in storage/secret.txt, which the
# first boot creates. storage/ isn't committed, so each checkout makes its
# own. Every process on this machine shares the file, and it lasts as long as
# storage/ does, with the data in it. Set SIDEREAL_SECRET instead when that
# isn't enough: on several machines, or on a disk a deploy replaces. Every
# process must have the same one, kept across deploys (`bin/sid secret` makes
# one). Changing the secret logs everyone out. It must be at least 64 bytes.
#
# Replace this to read it from somewhere else, ex. a vault. Or replace
# sidereal.secrets itself with anything that answers `derive(purpose)`.
secret_file = File.expand_path('../../storage/secret.txt', __dir__)

Sidereal.config.config!('sidereal.secret_key_base') do
  secret = ENV['SIDEREAL_SECRET'].to_s
  secret.empty? ? Sidereal::KeyGenerator.file_secret(secret_file) : secret
end
