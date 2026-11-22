# frozen_string_literal: true

# Sidereal signs the URLs of pages' live updates with the sidereal.signer
# component, so a client can only subscribe to the channels its pages name.
# Sidereal declares it, and the app implements it, here. A signer answers
# `generate(data, purpose:)` and `verify(token, purpose:)`: replace this one
# with your own, which may need no secret, or one from somewhere else.

# An HMAC-SHA256 signer, with a key derived from the app's secret (see
# secrets.rb).
Sidereal.config.config!('sidereal.signer', ['secrets']) do |secrets|
  Sidereal::Signer.new(secrets.derive('sidereal.signer'))
end
