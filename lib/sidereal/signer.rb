# frozen_string_literal: true

require 'base64'
require 'json'
require 'openssl'
require 'rack/utils'
require 'securerandom'

module Sidereal
  # Signs JSON data into URL-safe tokens, and verifies them. A token is the
  # Base64url-encoded JSON, a dot, and an HMAC-SHA256 of it under a secret:
  # anyone can read it, but only a holder of the secret can make one that
  # {#verify} accepts.
  #
  # Sidereal signs the URLs of pages' live updates streams with the
  # +sidereal.signer+ component, which an app implements, ex. with one of
  # these (+sid new+ writes +config/components/signer.rb+). An app can sign its
  # own data by injecting it:
  #
  #   dep 'sidereal.signer' => 'signer'
  #
  #   token = signer.generate({ 'invite' => 42 }, purpose: 'invites')
  #   signer.verify(token, purpose: 'invites') # => { 'invite' => 42 }
  #
  # A +purpose+ is mixed into the signature, so a token made for one use
  # can't be passed off as another's.
  class Signer
    # A secret shorter than this is rejected: HMAC-SHA256 is only as strong as
    # its key.
    MIN_SECRET_BYTES = 32

    DIGEST = 'SHA256'
    SEPARATOR = '.'

    # A new random secret, as hex: twice {MIN_SECRET_BYTES} characters.
    #
    # @return [String]
    def self.generate_secret = SecureRandom.hex(MIN_SECRET_BYTES)

    # @param secret [String] at least {MIN_SECRET_BYTES} bytes
    # @raise [ArgumentError] if +secret+ is shorter
    def initialize(secret)
      if secret.bytesize < MIN_SECRET_BYTES
        raise ArgumentError, "signer secret must be at least #{MIN_SECRET_BYTES} bytes"
      end

      @secret = secret
    end

    # @param data [Object] anything JSON can encode
    # @param purpose [String, nil] what the token is for
    # @return [String] a URL-safe token
    def generate(data, purpose: nil)
      payload = Base64.urlsafe_encode64(JSON.generate(data), padding: false)
      "#{payload}#{SEPARATOR}#{signature(payload, purpose)}"
    end

    # @param token [String]
    # @param purpose [String, nil] the purpose it was generated for
    # @return [Object, nil] the data, or +nil+ unless +token+ was generated
    #   with this signer's secret and this +purpose+
    def verify(token, purpose: nil)
      payload, digest, extra = token.to_s.split(SEPARATOR)
      return if payload.nil? || digest.nil? || extra
      return unless Rack::Utils.secure_compare(digest, signature(payload, purpose))

      JSON.parse(Base64.urlsafe_decode64(payload))
    rescue ArgumentError, JSON::ParserError
      nil
    end

    # Leaves the secret out, so logs, consoles and error messages don't show it.
    def inspect = "#<#{self.class.name}>"

    private

    def signature(payload, purpose)
      Base64.urlsafe_encode64(OpenSSL::HMAC.digest(DIGEST, @secret, "#{purpose}\0#{payload}"), padding: false)
    end
  end
end
