# frozen_string_literal: true

require 'fileutils'
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
  # The +sidereal.secrets+ component is one, from +sidereal.secret_key_base+.
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

    # How long {.file_secret} waits for another process to finish writing the
    # file, on a filesystem without hard links: attempts, and seconds apart.
    READ_ATTEMPTS = 50
    READ_INTERVAL = 0.01

    # The secret in the file at +path+, which is created with a new
    # {.generate_secret}, readable only by its owner, if it doesn't exist.
    # Processes that boot together all read the same secret: only the first
    # one to create the file writes it.
    #
    # The file appears whole: it's written under another name, then linked
    # into place. On a filesystem without hard links, it's created
    # exclusively instead, and a process that finds it still empty waits
    # for it to be written.
    #
    # @param path [String]
    # @return [String]
    def self.file_secret(path)
      create_secret_file(path) unless File.exist?(path)

      READ_ATTEMPTS.times do
        secret = File.read(path).strip
        return secret unless secret.empty?

        sleep READ_INTERVAL
      end
      File.read(path).strip
    end

    def self.create_secret_file(path)
      FileUtils.mkdir_p(File.dirname(path))
      secret = generate_secret
      draft = "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}"
      File.write(draft, secret, perm: 0o600)
      begin
        File.link(draft, path)
      rescue Errno::EEXIST
        # Another process created it first
      rescue SystemCallError
        # No hard links here
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(secret) }
      end
    rescue Errno::EEXIST
      # Another process created it first
    ensure
      FileUtils.rm_f(draft) if draft
    end
    private_class_method :create_secret_file

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
