# frozen_string_literal: true

# Sidereal signs the URLs of pages' live updates with the sidereal.signer
# component, so a client can only subscribe to the channels its pages name.
# Sidereal declares it, and the app implements it, here. A signer answers
# `generate(data, purpose:)` and `verify(token, purpose:)`: replace this one
# with your own, which may need no secret, or one from somewhere else.

# The secret, from SIDEREAL_SECRET: `sid new` wrote one to .env, which boot.rb
# loads. In production, set it in the environment, the same in every process
# and across deploys. `bin/sid secret` makes a new one.
Sidereal.config.declare('signer.secret', Sidereal::Types::String)
Sidereal.config.env('SIDEREAL_SECRET' => 'signer.secret')

# An HMAC-SHA256 signer, with a secret of at least 32 bytes.
Sidereal.config.config!('sidereal.signer', ['signer.secret']) do |secret|
  Sidereal::Signer.new(secret)
end
