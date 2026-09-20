# frozen_string_literal: true

require 'sourced/message/forms_codec'

module Sidereal
  # The web boundary's serializer, as {Sourced::Message::JSONCodec} is the
  # transports'. HTML forms carry every value as a String, in both directions:
  # a browser posts +"30"+ for an attribute typed +Types::Integer+, and an
  # +<input value="...">+ can only hold a String.
  #
  # Unlike the gem's {Sourced::Message::FormsCodec}, this one compiles the
  # *payload* schema rather than the whole message — the same seam override
  # +Sourced::Store::MessageCodec+ makes for the opposite reason. Two things
  # follow, and both are the point:
  #
  # - Decode errors are a flat +{attribute => message}+ hash, which is what
  #   +App#patch_command_errors+ streams back to a field.
  # - The envelope (+id+, +created_at+, +metadata+, +correlation_id+) is never
  #   read from the request. A browser cannot date a command into the future
  #   and have it land in the store's +scheduled/+ directory.
  #
  # Each {App} owns one, compiled from its +handled_commands+ — the commands it
  # exposed via +.handle+, which are the only ones a form submission can name.
  #
  # @see App.forms_codec
  class FormsCodec < Sourced::Message::FormsCodec
    # The whitelist. Holds the app class rather than a snapshot of its commands,
    # so +App.handle+ can append and then +recompile!+ to pick the new type up.
    HandledCommands = Data.define(:app) do
      def all(&block) = app.handled_commands.each_value(&block)
      def [](type) = app.handled_commands[type]
    end

    # Decode form params into a payload without raising. Form input is user
    # input: a failure is a validation result to render back into the field it
    # came from, not an exception.
    #
    # @param type [String] message type string
    # @param params [Hash, nil] symbol-keyed payload params, all values Strings.
    #   +nil+ for a command declaring no payload.
    # @return [Plumb::Result] +#value+ is a Payload instance (or nil), +#errors+
    #   a +{attribute => message}+ hash
    # @raise [UnregisteredTypeError] if the type was not compiled
    def resolve(type, params)
      pair(type, nil).decoder.resolve(params)
    end

    # Encode a command's payload into the Strings a form carries — the mirror of
    # {#resolve}, and like it non-raising.
    #
    # That matters more here than it looks. A form is rendered from whatever the
    # command holds so far: nothing at all for a blank +command AddTodo+ form,
    # half a payload for one being re-rendered mid-edit. +#parse+ would reject
    # both, but +#resolve+ is per-key — it returns the attributes that *are* set
    # and reports the rest as errors, which for rendering simply means "no value
    # yet". So callers use +#value+ and ignore +#errors+.
    #
    # @param message [Sidereal::Message]
    # @return [Plumb::Result] +#value+ is a +{attribute => String}+ hash, holding
    #   only the attributes that could be encoded (+{}+ for a blank command, +nil+
    #   for one declaring no payload)
    # @raise [UnregisteredTypeError] if the type was not compiled
    def encode_payload(message)
      pair(message.type, message.id).encoder.resolve(message.payload)
    end

    private

    # --- seams ----------------------------------------------------------------

    # The payload node off the class's schema rather than +klass::Payload+, so a
    # message declaring a shared payload class works. Keys are compared with
    # +to_sym+ because Plumb marks an optional key on the key itself.
    def compiled_type(klass)
      schema = klass._schema.to_h
      key = schema.keys.find { |k| k.to_sym == :payload }
      schema[key]
    end

    def encode_subject(message) = message.payload

    # The decoded payload is passed as an instance: Plumb structs short-circuit
    # on instances of themselves, so the message class does not re-parse it.
    def build(klass, attrs, decoder)
      klass.new(attrs.merge(payload: decoder.parse(attrs[:payload])))
    end
  end
end
