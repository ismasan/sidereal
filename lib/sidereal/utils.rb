# frozen_string_literal: true

module Sidereal
  # Generic string-shaping helpers reused across the framework.
  # These are explicit module functions — call as
  # +Sidereal::Utils.camel_case("...")+ rather than mixing in.
  module Utils
    module_function

    # +"clock tick"+ → +"ClockTick"+. Splits on non-alphanumerics and
    # capitalises each part. Leading digits are preserved as-is — so
    # +"5 minute"+ → +"5Minute"+ (callers needing a valid Ruby
    # constant should prefix the result themselves).
    def camel_case(str)
      str.to_s.split(/[^a-zA-Z0-9]+/).map { |part| part[0]&.upcase.to_s + part[1..].to_s }.join
    end

    # +"ChatApp::Commander"+ → +"chat_app_commander"+. Splits double-
    # colons, inserts underscores at camelCase / acronym boundaries,
    # downcases, then collapses runs of non-alphanumerics into single
    # underscores and trims leading/trailing underscores.
    def snake_case(str)
      str.to_s
         .gsub('::', '_')
         .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
         .gsub(/([a-z\d])([A-Z])/, '\1_\2')
         .downcase
         .gsub(/[^a-z0-9]+/, '_')
         .gsub(/^_+|_+$/, '')
    end
  end
end
