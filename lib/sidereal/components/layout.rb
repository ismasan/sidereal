# frozen_string_literal: true

require_relative 'base_component'

module Sidereal
  module Components
    class Layout < BaseComponent
      def initialize(page)
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

      def sidereal_head
        script(type: "module", src: 'https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.1/bundles/datastar.js')
      end

      def sidereal_signals
        page.page_signals.merge(params:)
      end

      def sidereal_foot
        return unless page.channel_name
        onload = _d.init.get(context.url("/updates/#{page.channel_name}", false))
        # onload needs to be at the end
        # to make sure to collect all signals on the page
        div(data: onload.to_h)
      end
    end
  end
end
