# frozen_string_literal: true

module Sidereal
  UnknownMessageError = Class.new(ArgumentError)

  class Message < Types::Data
    attribute? :channel, Types::String
    attribute :id, Types::AutoUUID

    class Registry
      def initialize(message_class)
        @message_class = message_class
        @lookup = {}
      end

      def keys = @lookup.keys
      def subclasses = message_class.subclasses

      def []=(key, klass)
        @lookup[key] = klass
      end

      def [](key)
        klass = lookup[key]
        return klass if klass

        subclasses.each do |c|
          klass = c.registry[key]
          return klass if klass
        end
        nil
      end

      def inspect
        %(<#{self.class}:#{object_id} #{lookup.size} keys, #{subclasses.size} child registries>)
      end

      private

      attr_reader :lookup, :message_class
    end

    def self.registry
      @registry ||= Registry.new(self)
    end

    def self.inherited(subclass)
      self.registry[subclass.name] = subclass
      super
    end

    def self.from(attrs)
      klass = registry[attrs[:type]]
      raise UnknownMessageError, "Unknown event type: #{attrs[:type]}" unless klass

      klass.new(attrs.fetch(:payload, Plumb::BLANK_HASH))
    end

    def to_h
      { type: self.class.name, payload: super }
    end

    def to_json(*)
      to_h.to_json(*)
    end
  end
end
