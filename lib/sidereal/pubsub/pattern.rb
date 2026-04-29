# frozen_string_literal: true

module Sidereal
  module PubSub
    # NATS-style channel pattern matching, shared by every PubSub backend.
    #
    #   `*` matches exactly one non-empty segment
    #       ("donations.*" matches "donations.111" but not "donations.111.created")
    #   `>` matches one or more non-empty segments; must be the trailing token
    #       ("donations.>" matches "donations.111" and "donations.222.created")
    #
    # All methods are pure — call them as +Pattern.wildcard?(name)+ etc.
    module Pattern
      SEGMENT_SEPARATOR = '.'

      # @param name [String]
      # @return [Boolean]
      def self.wildcard?(name)
        name.split(SEGMENT_SEPARATOR, -1).any? { |seg| seg == '*' || seg == '>' }
      end

      # Compile a subscription pattern into an anchored Regexp.
      # @param pattern [String]
      # @return [Regexp]
      def self.compile(pattern)
        parts = pattern.split(SEGMENT_SEPARATOR).map do |seg|
          case seg
          when '*' then '[^.]+'
          when '>' then '.+'
          else Regexp.escape(seg)
          end
        end
        Regexp.new('\A' + parts.join('\.') + '\z')
      end

      # @raise [ArgumentError] for empty patterns, empty segments, or non-trailing `>`.
      def self.validate_subscription!(pattern)
        raise ArgumentError, 'channel pattern must not be empty' if pattern.empty?

        segments = pattern.split(SEGMENT_SEPARATOR, -1)
        if segments.any?(&:empty?)
          raise ArgumentError, "empty segment in channel pattern #{pattern.inspect}"
        end

        segments.each_with_index do |seg, i|
          if seg == '>' && i != segments.size - 1
            raise ArgumentError,
                  "`>` wildcard must be the last segment in #{pattern.inspect}"
          end
        end
      end

      # @raise [ArgumentError] for empty names, empty segments, or any wildcard token.
      def self.validate_publish!(channel_name)
        raise ArgumentError, 'channel name must not be empty' if channel_name.empty?

        segments = channel_name.split(SEGMENT_SEPARATOR, -1)
        if segments.any?(&:empty?)
          raise ArgumentError, "empty segment in channel name #{channel_name.inspect}"
        end
        if segments.any? { |s| s == '*' || s == '>' }
          raise ArgumentError,
                "wildcards are not allowed when publishing: #{channel_name.inspect}"
        end
      end
    end
  end
end
