# frozen_string_literal: true

require 'rack'
require_relative 'components/exception_view'

module Sidereal
  # Rack middleware that answers an exception raised by the app with a report
  # of it (see {Components::ExceptionView}). For development only: it shows
  # backtraces and source to whoever made the request.
  #
  # A page request gets the report as a 500 page. A Datastar request (a
  # command form's +@post+, say) gets it as an overlay appended to the page's
  # +<body>+: a 200 +text/html+ response with Datastar's +selector+ and +mode+
  # headers, since the Datastar client ignores the body of any other status.
  #
  # An {App} defined in development is wrapped in it (see
  # {App.show_exceptions?}). Exceptions raised while an SSE response streams
  # happen after this middleware has returned, so such an app reports those
  # into the stream itself.
  class ShowExceptions
    HTML = 'text/html; charset=utf-8'

    def initialize(app)
      @app = app
    end

    def call(env)
      @app.call(env)
    rescue StandardError => ex
      Console.error(self, 'Unhandled exception', exception: ex)
      request = Rack::Request.new(env)
      if request.get_header('HTTP_DATASTAR_REQUEST')
        overlay = Components::ExceptionView.new(ex, request:, overlay: true).call
        [200, { 'content-type' => HTML, 'datastar-selector' => 'body', 'datastar-mode' => 'append' }, [overlay]]
      else
        [500, { 'content-type' => HTML }, [Components::ExceptionView.new(ex, request:).call]]
      end
    end
  end
end
