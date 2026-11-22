# frozen_string_literal: true

require 'sidereal/signer'

module Sidereal
  module CLI
    # `sid secret`: print a new random secret, for SIDEREAL_SECRET.
    class Secret < Command
      self.description = 'Print a new secret for SIDEREAL_SECRET'

      options do
        option '-h/--help', 'Print usage'
      end

      def call
        return print_usage if @options[:help]

        terminal.puts Sidereal::Signer.generate_secret
      end
    end
  end
end
