# frozen_string_literal: true

require_relative 'base_component'

module Sidereal
  module Components
    class Layout < BaseComponent
      def initialize(page)
        raise ArgumentError, "expected Sidereal::Page, but got #{page.inspect}" unless page.is_a?(Sidereal::Page)

        @page = page
      end

      def head(**args, &)
        super(**args) do
          yield

          sidereal_head
        end
      end

      def body(**args, &)
        data = args[:data] || {}
        signals = page.page_signals.merge(params:)
        signals.merge!(data[:signals]) if data[:signals]
        signals = _d.signals(signals).to_h
        data = data.merge(signals)
        super(**args.merge(data:)) do
          yield

          sidereal_foot
        end
      end

      private

      attr_reader :page

      # The app's stylesheets, the app's scripts, then Datastar, as the
      # +sidereal.assets.mode+ has them: each one, or their bundles. Module
      # scripts run in document order, so the app's custom elements and event
      # listeners are in place before Datastar applies itself to the page.
      # The asset tags are marked +data-sidereal-asset+, for live reload to
      # find (see {Sidereal::Assets::LiveReload::SCRIPT}).
      def sidereal_head
        assets = context.class.assets if context.class.respond_to?(:assets)
        assets&.stylesheet_hrefs(script_name: context.script_name)&.each do |href|
          link(rel: 'stylesheet', href:, data_sidereal_asset: true)
        end
        assets&.javascript_hrefs(script_name: context.script_name)&.each do |src|
          script(type: 'module', src:, data_sidereal_asset: true)
        end
        script(type: "module", src: 'https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.5/bundles/datastar.js')
      end

      # The URL of this page's live updates stream, carrying its signed
      # token, or +nil+ when it takes none. See {Page.stream_token}.
      def updates_url
        token = Sidereal::Page.stream_token(page, params, context)
        context.url("#{Sidereal::Page::UPDATES_PATH}/#{token}", false) if token
      end

      def sidereal_signals
        page.page_signals.merge(params:)
      end

      def sidereal_foot
        # Container for system notification toasts (NotifyRetry,
        # NotifyFailure). Page reactions prepend into this element so
        # toasts overlay the page rather than pushing content down.
        # Empty when no notifications are active — its fixed positioning
        # keeps it 0×0 visually until a toast lands inside.
        div(id: 'sidereal-sysnotify-stack')

        return unless (url = updates_url)

        onload = _d.init.get(url)
        # onload needs to be at the end
        # to make sure to collect all signals on the page
        div(data: onload.to_h)
      end
    end
  end
end
