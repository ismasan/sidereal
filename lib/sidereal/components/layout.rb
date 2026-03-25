# frozen_string_literal: true

require_relative 'base_component'

module Sidereal
  module Components
    class Layout < BaseComponent
      def initialize(page)
        @page = page
      end

      private

      attr_reader :page

      def sidereal_signals
        _d.signals(page.page_signals.merge(params:))
      end

      def sidereal_head
        script(type: "module", src: "https://cdn.jsdelivr.net/gh/starfederation/datastar@1.0.0-RC.8/bundles/datastar.js")
      end

      def sidereal_foot
        onload = _d.init.get('/updates')
        # onload needs to be at the end
        # to make sure to collect all signals on the page
        div(data: onload.to_h)
      end
    end
  end
end
