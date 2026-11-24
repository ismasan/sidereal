# frozen_string_literal: true

module Sidereal
  # JavaScript the framework sends to pages, through Datastar's +execute_script+.
  module Scripts
    # A function of a sessionStorage +key+ that reloads the page, at most once
    # every 10 seconds per tab for that key, so a reload that doesn't fix
    # what caused it can't loop. Where sessionStorage is unavailable, as some
    # browsers' privacy settings make it, it doesn't reload, since nothing
    # would stop such a loop.
    THROTTLED_RELOAD = <<~JS.gsub(/\s*\n\s*/, ' ').strip
      ((key) => {
        const now = Date.now();
        try {
          if (now - Number(sessionStorage.getItem(key) || 0) <= 10000) return;
          sessionStorage.setItem(key, String(now));
        } catch (_) { return; }
        location.reload();
      })
    JS
  end
end
