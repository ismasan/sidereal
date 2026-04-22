# frozen_string_literal: true

module Sidereal
  module RequestHelpers
    # Generates the absolute URI for a given path in the app.
    # Takes Rack routers and reverse proxies into account.
    def url(addr = nil, absolute = true, add_script_name = true)
      return addr if addr.to_s =~ /\A[a-z][a-z0-9+.\-]*:/i

      uri = String.new
      if absolute
        uri << "http#{'s' if request.ssl?}://"
        default_port = request.ssl? ? 443 : 80
        uri << if request.port != default_port
                  request.host_with_port
                else
                  request.host
                end
      end
      uri << script_name if add_script_name
      uri << (addr || request.path_info).to_s
      uri
    end

    # Returns the script name (path prefix) for the current request.
    # Override in subclasses to provide a stable snapshot (e.g. Router snapshots
    # SCRIPT_NAME at init time so async SSE fibers see the correct prefix even
    # after Rack::URLMap restores it in its ensure block).
    def script_name
      request.script_name.to_s
    end

    alias to url
  end
end
