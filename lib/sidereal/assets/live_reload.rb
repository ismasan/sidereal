# frozen_string_literal: true

require 'json'
require_relative '../scripts'

module Sidereal
  class Assets
    # Brings one open page's assets up to date when they change, over its
    # live updates stream: the page side of live reload. A {Watcher}
    # publishes {Changed} on {CHANNEL}, which a page stream subscribes to
    # while {.enabled?}, and the stream's page reacts with {#sync}.
    class LiveReload
      # Brings the page's asset tags up to date, given the current URLs of the
      # app's stylesheets and scripts: a stylesheet whose URL changed is
      # replaced by a new +<link>+, and the old one removed once the new one
      # loads, so the page isn't left unstyled meanwhile. A changed script, or a
      # different number of tags, reloads the page, through
      # {Scripts::THROTTLED_RELOAD}.
      SCRIPT = <<~JS.gsub(/\s*\n\s*/, ' ').strip
        ((css, js) => {
          const tags = (type, attr) => [...document.querySelectorAll(`${type}[data-sidereal-asset]`)].map((el) => [el, el.getAttribute(attr)]);
          const links = tags('link', 'href'), scripts = tags('script', 'src');
          const same = (list, urls) => list.length === urls.length && list.every(([, url], i) => url === urls[i]);
          if (links.length !== css.length || !same(scripts, js)) return #{Scripts::THROTTLED_RELOAD}('sidereal.assets-reload');
          links.forEach(([old, url], i) => {
            if (url === css[i]) return;
            const link = old.cloneNode();
            old.removeAttribute('data-sidereal-asset');
            link.href = css[i];
            link.onload = link.onerror = () => old.remove();
            old.after(link);
          });
        })
      JS

      # Whether the +sidereal.assets.live_reload+ component is on: +false+ when
      # the components aren't built.
      #
      # @return [Boolean]
      def self.enabled? = Assets.setting('sidereal.assets.live_reload', false)

      # @param browser [#execute_script, #patch_elements] the page's stream
      # @param ctx [Sidereal::App] the stream request's app instance
      def initialize(browser, ctx)
        @browser = browser
        @context = ctx
        @files = nil
      end

      # Bring the browser's asset tags up to date with the app's current
      # assets (see {SCRIPT}), and with +rerender+, patch in the page the
      # block renders if a file it may link, such as an image, changed since
      # the last sync. A no-op for an app without assets.
      #
      # @param rerender [Boolean]
      # @yieldreturn [Phlex::SGML] the page, rendered again
      # @return [void]
      def sync(rerender: true)
        return unless @context.class.respond_to?(:assets)

        assets = @context.class.assets
        css = assets.stylesheet_hrefs(script_name: @context.script_name)
        js = assets.javascript_hrefs(script_name: @context.script_name)
        @browser.execute_script("#{SCRIPT}(#{JSON.generate(css, script_safe: true)}, #{JSON.generate(js, script_safe: true)})")

        files = assets.digests(:file)
        @browser.patch_elements yield if rerender && @files && files != @files
        @files = files
      end
    end
  end
end
