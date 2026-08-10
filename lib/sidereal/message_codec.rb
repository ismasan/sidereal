# frozen_string_literal: true

require 'plumb'
require 'sidereal/message'

module Sidereal
  # Serializes whole messages for Sidereal's own transports — {Store::FileSystem}
  # (one JSON document per file) and {PubSub::Unix} (one JSON frame per line).
  #
  #   codec = Sidereal.message_codec
  #   codec.encode(message)  # => JSON-native Hash
  #   codec.decode(attrs)    # => the message
  #
  # It holds a compiled +[decoder, encoder]+ {Pair} per message class, keyed by
  # type string. {#compile!} builds them all; a type missing from the result
  # raises rather than compiling mid-request.
  #
  # The pair covers the *whole* message, envelope included, because these
  # transports carry a message as a single document with nowhere to put an
  # envelope separately. Sourced's own +Store::MessageCodec+ registers only the
  # payload type — its store keeps the envelope in columns — so the two keep
  # separate compiled registries. They read the same root message registry and
  # the same format, so a type encoded by one is decodable by the other.
  #
  # The format is +Plumb::Codec::JSON+ and is not configurable: it is the same
  # global Sourced uses, so an encoder registered on it teaches every serializer
  # in the process at once.
  #
  #   Plumb::Codec::JSON.encoder(MoneyEncoder)
  #
  # Register at load time. Both serializers compile their message types at boot,
  # and neither notices an encoder that arrives afterwards.
  class MessageCodec
    # Raised when a message being written can't be represented in the codec's
    # format, which in practice means the message itself is invalid.
    EncodeError = Class.new(Error)

    # Raised when a serialized message no longer satisfies its class's schema —
    # a schema change, a hand-edited file, a foreign writer.
    DecodeError = Class.new(Error)

    # Raised when asked for a type {#compile!} never saw — defined after the
    # compile, or absent from this process entirely.
    UnregisteredTypeError = Class.new(Error)

    # A message class's compiled +[decoder, encoder]+ for one format.
    Pair = Data.define(:decoder, :encoder)

    # The instance the transports share. Holding no connections or file handles,
    # it is safe to share, so a process compiles its pairs once. Pass +codec:+ to
    # a store or pubsub to give it its own.
    #
    # @return [MessageCodec]
    def self.default = @default ||= new

    # Drop the shared instance, so the next {.default} compiles against the
    # current registry. Called by {Sidereal.reload!} — between tests, and by a
    # development-mode class reloader.
    #
    # The {.pairs} cache deliberately survives: building a pair is the expensive
    # part of a compile, and a class that did not change does not need a new one.
    #
    # @return [void]
    def self.reset!
      @default = nil
    end

    # Compiled pairs, keyed by message class, shared across every instance and
    # every reset. A class's schema is fixed once its +define+ block has run, so
    # its pair is too — which makes recompiling after a reload a matter of
    # re-collecting existing pairs rather than rebuilding them. Redefining a
    # message type produces a *new* class, so it misses the cache and compiles
    # fresh, which is what makes this safe for reloading. (Reopening a class to
    # add attributes after it has been compiled once would not be picked up;
    # {.clear_pairs!} is the way out of that.)
    #
    # Held strongly. A weakly-keyed map would not help: a pair is built from its
    # class and refers back to it, so holding the pair keeps the class reachable
    # either way. A reloader that discards classes should call {.clear_pairs!}.
    #
    # @return [Hash{Class => Hash{Class<Plumb::Codec> => Pair}}]
    def self.pairs
      @pairs ||= {}
    end

    # Discard cached pairs, so every class is compiled again. For a reloader
    # dropping classes, and for a class whose schema changed in place — which
    # {.reset!} cannot detect, since the class is the same object.
    #
    # @return [void]
    def self.clear_pairs!
      @pairs = nil
    end

    # @return [Class<Plumb::Codec>] the format compiled onto message types
    attr_reader :format

    # @param format [Class<Plumb::Codec>] the codec class compiled onto message
    #   types. A seam for scoping a codec to its own format, as specs do; the
    #   format itself needs no configuring.
    # @param registry [Sourced::Message::Registry] resolves type strings to
    #   classes. Defaults to the shared root registry, which recurses into every
    #   subclass registry — so Sourced types travelling through Sidereal's
    #   transports encode and decode like Sidereal's own.
    def initialize(format: Plumb::Codec::JSON, registry: Sourced::Message.registry)
      @format = format
      @registry = registry
      @messages = nil
    end

    # +attr_reader :format+ shadows +Kernel#format+ in instance scope, so this
    # interpolates.
    #
    # @return [String]
    def inspect = "#<#{self.class.name} format=#{@format.name}#{compiled? ? '' : ' (not compiled)'}>"

    # @return [Boolean] whether {#compile!} has run
    def compiled? = !@messages.nil?

    # Build the registry: a pair for every message class, frozen once they are
    # all in.
    #
    # Also the boot check: a message type this codec cannot represent raises
    # here, naming the offending attribute path. Every transport that serializes
    # calls this from its own +#start+, so the failure lands at boot — before any
    # message is written — for whichever transports an app actually runs.
    #
    # Idempotent, so each of them can call it without coordinating: the second
    # and later calls return immediately. {.reset!} is what makes a fresh compile
    # happen, by handing out a new instance.
    #
    # Note what it does *not* check: whether data already written satisfies its
    # schema. That is a per-message question, answered by {#decode} when the
    # message is read.
    #
    # @return [self]
    # @raise [Plumb::TypeError] if any registered message type can't be
    #   serialized by this codec
    def compile!
      return self if compiled?

      messages = {}
      @registry.all { |klass| messages[klass.type] = pair_for(klass) }
      @messages = messages.freeze
      self
    end

    # @param type [String] message type string
    # @return [Boolean] whether a pair was compiled for this type
    def registered?(type) = compiled_messages.key?(type)

    # Encode a message into JSON-native values, ready for +JSON.dump+.
    #
    # @param message [Sourced::Message]
    # @return [Hash]
    # @raise [EncodeError] if the message doesn't satisfy its own schema
    # @raise [UnregisteredTypeError] if the type was not compiled
    def encode(message)
      pair(message.type, message.id).encoder.parse(message)
    rescue Plumb::ParseError => e
      raise EncodeError, "cannot encode #{label(message.type, message.id)}: #{e.message}"
    end

    # Rebuild a message from decoded JSON attributes. An unregistered type
    # raises: a process reading types it doesn't know about is missing the class.
    #
    # @param attrs [Hash] symbol-keyed message attributes
    # @return [Sourced::Message]
    # @raise [Sourced::Message::UnknownMessageError] if the type isn't in the registry
    # @raise [UnregisteredTypeError] if the type was not compiled
    # @raise [DecodeError] if the attributes don't satisfy the schema
    def decode(attrs)
      type = attrs[:type]
      raise Sourced::Message::UnknownMessageError, "Unknown message type: #{label(type, attrs[:id])}" unless @registry[type]

      pair(type, attrs[:id]).decoder.parse(attrs)
    rescue Plumb::ParseError => e
      raise DecodeError, "cannot decode #{label(type, attrs[:id])}: #{e.message}"
    end

    private

    # Compiling on first use keeps the codec usable without a {Host} — a test or
    # a script that reaches for a store directly gets a working codec. Apps do
    # not rely on this: {Host#start} compiles eagerly, so an unserializable type
    # fails their boot rather than their first message.
    def compiled_messages
      compile! unless compiled?
      @messages
    end

    # @raise [UnregisteredTypeError] naming the message, so the caller knows
    #   which type was missing rather than only that one was
    def pair(type, id)
      compiled_messages[type] ||
        raise(UnregisteredTypeError, "no encoder/decoder compiled for #{label(type, id)}")
    end

    # The class's pair for this format, built once per class and reused across
    # every recompile. Building it is the whole cost of a compile — the rewrite
    # walks the schema and resolves an encoder for every leaf.
    def pair_for(klass)
      by_format = self.class.pairs[klass] ||= {}
      by_format[@format] ||= Pair.new(*@format.for(klass))
    end

    # "orders.placed (a1b2c3…)" — enough to find the offending message.
    def label(type, id) = "#{type} (#{id})"
  end
end
