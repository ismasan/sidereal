# frozen_string_literal: true

require 'console'

module Sidereal
  # Silence Async's noisy "Task may have ended with unhandled exception"
  # WARNINGS for the benign client disconnects that are constant in an
  # SSE-streaming app.
  #
  # When a browser drops its +/updates+ connection, async-http's server task
  # (and Datastar's stream teardown) raise +Errno::EPIPE+ ("Broken pipe") while
  # writing the next chunk to the now-dead socket. Async logs any task that ends
  # on an unhandled exception at +:warn+, so the log fills with these on every
  # disconnect.
  #
  # Datastar's AsyncExecutor tries to suppress this with
  # +Console.logger.disable(Async::Task)+, but the Console logger is
  # fiber/thread-local (via the +fiber-local+ gem), so a one-off disable on the
  # boot fiber doesn't reliably reach async-http's connection tasks. Instead we
  # hook the single method the console gem uses to build *every* logger
  # (+Console::Config#make_logger+), disabling the subject on each one — on any
  # thread or fiber. This is the same effect as a project-level
  # +config/console.rb+, but shipped in the gem so every Sidereal app gets it for
  # free.
  #
  # Set +CONSOLE_LEVEL=debug+ (or +=info+) in the environment to re-enable full
  # output while debugging.
  module Logging
    # Prepended onto {Console::Config} so it wraps logger construction. Works
    # even though +Console::Config::DEFAULT+ is already frozen — freezing the
    # instance doesn't stop method resolution from walking the prepend.
    module DisableAsyncTaskWarnings
      def make_logger(...)
        super.tap do |logger|
          # Async::Task may be undefined when the first logger is built during
          # +require "console"+; it is loaded by the time serving loggers are
          # created, which are the ones that matter.
          logger.disable(::Async::Task) if defined?(::Async::Task)
        end
      end
    end

    module_function

    # Install the global filter. Idempotent — safe to call more than once.
    #
    # @return [void]
    def quiet_async_disconnect_warnings!
      return if ::Console::Config.include?(DisableAsyncTaskWarnings)

      ::Console::Config.prepend(DisableAsyncTaskWarnings)
      # make_logger only affects loggers built from here on, so also disable on
      # the current thread's logger in case it was already created (and the
      # reactor ends up serving on this thread).
      ::Console.logger.disable(::Async::Task) if defined?(::Async::Task)
    end
  end
end

Sidereal::Logging.quiet_async_disconnect_warnings!
