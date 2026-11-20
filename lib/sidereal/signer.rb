# frozen_string_literal: true

require 'base64'
require 'json'
require 'openssl'
require 'rack/utils'

module Sidereal
  # Signs JSON data into URL-safe tokens, and verifies them. A token is the
  # Base64url-encoded JSON, a dot, and an HMAC-SHA256 of it under a secret:
  # anyone can read it, but only a holder of the secret can make one that
  # {#verify} accepts.
  #
  # The +sidereal.signer+ component is one when {ENV_KEY} is set, and an
  # {Unsigned} encoder otherwise (see {.default}). Sidereal signs the URLs of
  # pages' live updates streams with it, and an app can sign its own data by
  # injecting it:
  #
  #   dep 'sidereal.signer' => 'signer'
  #
  #   token = signer.generate({ 'invite' => 42 }, purpose: 'invites')
  #   signer.verify(token, purpose: 'invites') # => { 'invite' => 42 }
  #
  # A +purpose+ is mixed into the signature, so a token made for one use
  # can't be passed off as another's.
  class Signer
    # The secret {.default} signs with.
    ENV_KEY = 'SIDEREAL_SECRET'

    # A secret shorter than this is rejected: HMAC-SHA256 is only as strong as
    # its key.
    MIN_SECRET_BYTES = 32

    DIGEST = 'SHA256'
    SEPARATOR = '.'

    # Encodes data into URL-safe tokens without signing them: {#verify}
    # decodes any token {#generate} could have made, including one a client
    # wrote itself. Good enough for development, where it spares a secret.
    # Set {ENV_KEY}, or implement +sidereal.signer+, wherever clients must
    # not forge tokens.
    class Unsigned
      # @param data [Object] anything JSON can encode
      # @param purpose [String, nil] what the token is for
      # @return [String] a URL-safe token
      def generate(data, purpose: nil)
        Base64.urlsafe_encode64(JSON.generate([purpose, data]), padding: false)
      end

      # @param token [String]
      # @param purpose [String, nil] the purpose it was generated for
      # @return [Object, nil] the data, or +nil+ unless +token+ decodes to
      #   data for this +purpose+
      def verify(token, purpose: nil)
        decoded = JSON.parse(Base64.urlsafe_decode64(token.to_s))
        return unless decoded.is_a?(Array) && decoded.size == 2 && decoded.first == purpose

        decoded.last
      rescue ArgumentError, JSON::ParserError
        nil
      end
    end

    # What +sidereal.signer+ defaults to: a {Signer} with the secret in
    # {ENV_KEY} when it's set, or else an {Unsigned} encoder, with a warning.
    #
    # @return [Signer, Unsigned]
    def self.default
      secret = ENV[ENV_KEY]
      return new(secret) if secret && !secret.empty?

      Console.warn(
        self,
        "#{ENV_KEY} isn't set: pages' live updates URLs are encoded but not signed, " \
        'so a client can subscribe to any channel by writing its own. Set it to a random string of at least ' \
        "#{MIN_SECRET_BYTES} bytes, the same in every process."
      )
      Unsigned.new
    end

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

    private

    def signature(payload, purpose)
      Base64.urlsafe_encode64(OpenSSL::HMAC.digest(DIGEST, @secret, "#{purpose}\0#{payload}"), padding: false)
    end
  end
end
