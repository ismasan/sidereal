# frozen_string_literal: true

require 'openssl'
require 'securerandom'

module Sidereal
  # Derives a key for each purpose from one master secret, with HKDF-SHA256,
  # so an app keeps one secret, and each use of it gets a key of its own:
  #
  #   secrets = Sidereal::KeyGenerator.new(ENV.fetch('SIDEREAL_SECRET'))
  #   Sidereal::Signer.new(secrets.derive('sidereal.signer'))
  #   secrets.derive('session') # => a different key
  #
  # A derived key gives away neither the master secret nor the other keys.
  # The same secret and purpose always derive the same key, so every process
  # with the secret derives alike.
  class KeyGenerator
    # A secret shorter than this is rejected.
    MIN_SECRET_BYTES = 64

    # The length of the keys {#derive} returns by default: what
    # +Rack::Session::Cookie+ requires of its secret.
    KEY_BYTES = 64

    DIGEST = 'SHA256'

    # A new random secret: 32 random bytes as hex, which is
    # {MIN_SECRET_BYTES} characters.
    #
    # @return [String]
    def self.generate_secret = SecureRandom.hex(MIN_SECRET_BYTES / 2)

    # @param secret [String] at least {MIN_SECRET_BYTES} bytes
    # @raise [ArgumentError] if +secret+ is shorter
    def initialize(secret)
      if secret.bytesize < MIN_SECRET_BYTES
        raise ArgumentError, "master secret must be at least #{MIN_SECRET_BYTES} bytes"
      end

      @secret = secret
    end

    # @param purpose [String] what the key is for
    # @param length [Integer] in bytes
    # @return [String] a binary key
    def derive(purpose, length: KEY_BYTES)
      OpenSSL::KDF.hkdf(@secret, salt: '', info: purpose, length:, hash: DIGEST)
    end

    # Leaves the secret out, so logs, consoles and error messages don't show it.
    def inspect = "#<#{self.class.name}>"
  end
end
