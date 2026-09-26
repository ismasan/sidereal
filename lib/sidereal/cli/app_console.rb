# frozen_string_literal: true

module Sidereal
  module CLI
    # `sid console`: IRB with the app loaded. Only registered by an app's
    # bin/sid (see {CLI.load_app}). Not named Console, which would hide the
    # console gem's Console (and Console::Terminal) inside Sidereal::CLI.
    class AppConsole < Command
      self.description = 'Start an IRB session with the app loaded'

      def call
        CLI.boot_app!
        require 'irb'
        # IRB reads its own options from ARGV, which still holds `console`.
        ARGV.clear
        IRB.start
      end
    end
  end
end
