# frozen_string_literal: true

require 'json'

module UI
  module Booking
    # The Diagram tab: HolidayBooking as a statechart, with the booking's active
    # checkpoints lit, and its configuration as `machine.value` returns it.
    class DiagramPage < Frame
      path '/bookings/:booking_id/diagram'

      def tab = :diagram

      private

      # The diagram takes the content's full width.
      def basket? = false

      def render_lead
        p(class: 'booking__lead') { 'Each checkpoint is an event in the booking’s history.' }
      end

      def render_tab
        section(class: 'machine-view', aria: { label: 'Statechart' }) do
          render Components::Statechart.new(@booking.to_h, title: 'HolidayBooking statechart')
          render Components::StatechartLegend.new
          pre(class: 'machine-view__value') do
            code { "# machine.value\n#{JSON.pretty_generate(json_value(@machine.value))}" }
          end
        end
      end

      # machine.value with checkpoint classes as their short names and region
      # positions as strings, so it reads as JSON.
      def json_value(value)
        case value
        when Hash then value.to_h { |k, v| [json_value(k), json_value(v)] }
        when Class then value.name.split('::').last
        else value.to_s
        end
      end
    end
  end
end
