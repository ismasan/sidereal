# frozen_string_literal: true

require 'securerandom'
require 'tempfile'
require 'plumb'
require_relative 'pubsub/pattern'

module Sidereal
  module Types
    include Plumb::Types

    AutoUUID = UUID::V4.default { SecureRandom.uuid }

    # A channel pattern that can be subscribed to, as
    # {PubSub::Pattern.validate_subscription!} accepts: +*+ and a trailing +>+
    # are wildcards.
    ChannelPattern = String >> lambda { |result|
      error = PubSub::Pattern.subscription_error(result.value)
      error ? result.invalid(errors: error) : result
    }

    # A file uploaded through a multipart form, in the shape provided by Rack.
    # Declare a command attribute with it, refining it as any struct:
    #
    #   attribute :report, Sidereal::Types::UploadedFile.where(type: 'application/pdf')
    #
    # Both of Sidereal's formats carry it. A form posts the Rack upload Hash, which
    # decodes as it is. JSON has no file type, so a store or pub/sub frame carries
    # the file's bytes Base64-encoded, and decoding writes them to a new Tempfile.
    class UploadedFile < Data
      attribute :filename, String
      attribute :type, String
      attribute :name, String
      attribute :tempfile, ::Tempfile
      attribute :head, String
    end

    # The JSON form of an {UploadedFile}: its fields, with +tempfile+ replaced by
    # +data+, the file's bytes in strict Base64.
    class UploadedFileJSONEncoder < Plumb::Encoder[
      Plumb::Types::Hash[filename: String, type: String, name: String, head: String, data: String] => UploadedFile
    ]
      def encode(file)
        {
          filename: file.filename,
          type: file.type,
          name: file.name,
          head: file.head,
          data: [read(file.tempfile)].pack('m0')
        }
      end

      def decode(hash)
        tempfile = ::Tempfile.new(['sidereal-upload', File.extname(hash[:filename])], binmode: true)
        tempfile.write(hash[:data].unpack1('m0'))
        tempfile.rewind
        UploadedFile.new(
          filename: hash[:filename],
          type: hash[:type],
          name: hash[:name],
          head: hash[:head],
          tempfile:
        )
      end

      private

      # Reads the whole file and puts the handle back where it was, since the
      # handler that holds the upload may be partway through reading it.
      def read(io)
        pos = io.pos
        begin
          io.rewind
          io.read.b
        ensure
          io.pos = pos
        end
      end
    end

    # Registered as this file loads, before any message type is defined, because
    # each codec works out its encoders and pass-through types on its first compile.
    #
    # Forms passes the Tempfile Rack hands over through unchanged. The rewriter
    # recurses into the struct, and the Tempfile is the only field it can't decode.
    Plumb::Codec::Forms.noop(::Tempfile)
    Plumb::Codec::JSON.encoder(UploadedFileJSONEncoder)
  end
end
