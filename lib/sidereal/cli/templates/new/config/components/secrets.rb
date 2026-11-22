# frozen_string_literal: true

# The app's master secret, and the keys derived from it: the signer's, in
# signer.rb, and the session cookie's, in web/app.rb. Each derives its own
# key with `Sidereal.config['secrets'].derive('<purpose>')`, so one secret
# serves them all, and a key for one purpose can't stand in for another's.
# Replace `secrets` with your own, ex. one that reads a vault, and every
# key comes from it.

# The secret, from SIDEREAL_SECRET: `sid new` wrote one to .env, which boot.rb
# loads. In production, set it in the environment, the same in every process
# and across deploys. `bin/sid secret` makes a new one. Changing it logs
# everyone out. It must be at least 64 bytes.
Sidereal.config.declare('secrets.base', Sidereal::Types::String.where(bytesize: Sidereal::KeyGenerator::MIN_SECRET_BYTES..))
Sidereal.config.env('SIDEREAL_SECRET' => 'secrets.base')

# Derives keys from the secret with HKDF-SHA256.
Sidereal.config.declare('secrets', Sidereal::Types::Interface[:derive])
Sidereal.config.config!('secrets', ['secrets.base']) do |base|
  Sidereal::KeyGenerator.new(base)
end
