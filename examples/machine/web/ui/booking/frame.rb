# frozen_string_literal: true

module UI
  module Booking
    # What every page of a booking shares: the header, the Booking / Diagram tabs,
    # the trip's basket and, on wide screens, the history feed. Subclasses are the
    # tabs: each sets its path and renders its panel in #render_tab.
    #
    # A page renders the booking as it is now, or as it was at a step of its
    # history (see .at). A past step is a static render: it doesn't subscribe to
    # updates, and its forms are disabled, since a command would apply to the
    # booking as it is now.
    class Frame < Sidereal::Page
      # Every event the machine evolves: its checkpoints and its data.
      on HolidayBooking

      TABS = { booking: 'Booking', diagram: 'Diagram' }.freeze

      def self.load(params, _ctx) = new(History.load(params[:booking_id]))

      # The page at +step+ of the booking's history, or nil when there's no such step.
      def self.at(booking_id, step)
        history = History.load(booking_id, step:)
        new(history) if step.between?(1, history.messages.size)
      end

      # @param history [History]
      def initialize(history)
        @history = history
        @booking = history.booking
        @trip = @booking.context
        @machine = @booking.machine
      end

      # A past step listens to nothing, and has no page_key for an update to reload.
      def channel_name = @history.live? ? "bookings.#{booking_id}" : nil
      def page_signals = @history.live? ? super : {}

      # @return [Symbol] this page's key in TABS
      def tab = raise(NotImplementedError)

      def view_template
        div(id: 'booking-page', class: 'booking') do
          div(class: 'sky', aria: { hidden: 'true' })

          div(class: 'booking__content') do
            if @trip.started?
              render_header
              render_time_travel unless @history.live?
              render_tabs
              render_lead
              # The panel and the basket start level with each other, below the
              # tabs and the lead.
              div(class: ['booking__body', ('booking__body--full' unless basket?)]) do
                div(class: 'booking__panel', role: 'tabpanel', aria: { label: TABS.fetch(tab) }) do
                  if @history.live?
                    render_tab
                  else
                    fieldset(class: 'booking__frozen', disabled: true) { render_tab }
                  end
                end
                render_basket if basket?
              end
            else
              render_pending
            end
          end

          render Components::HistoryFeed.new(
            messages: @history.messages,
            current_step: @history.current_step,
            live: @history.live?,
            live_href: tab_path(tab),
            step_href: ->(step) { tab_path(tab, step) },
            prefix: 'holidays.',
            hide: %i[booking_id]
          )
        end
      end

      private

      def booking_id = @history.booking_id

      # A line introducing the tab, above its panel. None by default.
      def render_lead; end

      # Whether the tab shows the trip's basket beside its panel.
      def basket? = true

      # This booking's page for +tab+, live or at +step+.
      def tab_path(tab, step = nil)
        path = tab == :booking ? "/bookings/#{booking_id}" : "/bookings/#{booking_id}/diagram"
        step ? "#{path}/at/#{step}" : path
      end

      # The command forms on these pages all carry the booking's id, and nothing
      # else the traveller types: each option is its own form with one button.
      def action(command_class, label, key: 'cmd', css: 'button', fields: {}, **attrs)
        command command_class, key:, class: 'inline-form' do |f|
          f.payload_fields(booking_id:, **fields)
          button(type: :submit, class: css, **attrs) { label }
        end
      end

      def render_header
        destination = @trip.destination_info
        header(class: 'booking__header') do
          p(class: 'eyebrow') { a(href: '/') { 'Sidereal Holidays' } }
          h1(class: 'booking__title') { "#{destination.name}, #{destination.country}" }
          p(class: 'booking__meta') do
            plain "#{@trip.depart_on.strftime('%-d %b %Y')} – #{@trip.return_on.strftime('%-d %b %Y')}"
            plain " · #{@trip.nights} nights · #{pluralize(@trip.travellers, 'traveller')}"
          end
        end
      end

      def render_time_travel
        message = @history.messages[@history.current_step - 1]
        p(class: 'time-travel', role: 'status') do
          plain "Step #{@history.current_step} of #{@history.messages.size}: the booking as it was after "
          code { message.type }
          plain '. '
          a(href: tab_path(tab)) { 'Back to live' }
        end
      end

      def render_tabs
        nav(class: 'tabs', aria: { label: 'Booking views' }) do
          TABS.each do |key, label|
            current = key == tab
            a(
              href: tab_path(key, @history.step),
              class: ['tabs__tab', ('tabs__tab--current' if current)],
              aria: { current: current ? 'page' : nil }
            ) { label }
          end
        end
      end

      def render_basket
        aside(class: 'basket', aria: { label: 'Your trip so far' }) do
          h2(class: 'basket__title') { 'Your trip' }
          if @trip.lines.empty?
            p(class: 'basket__empty') { 'Nothing picked yet.' }
          else
            dl(class: 'basket__lines') do
              @trip.lines.each do |label, amount|
                dt { label }
                dd { euros(amount) }
              end
            end
          end
          p(class: 'basket__total') do
            span { 'Total' }
            strong { euros(@trip.total) }
          end
          if @history.live? && (@machine.in?(HolidayBooking::BookingStarted) || @machine.in?(HolidayBooking::ItineraryReady))
            action HolidayBooking::CancelBooking, 'Cancel booking', css: 'button button--quiet'
          end
        end
      end

      def render_pending
        header(class: 'booking__header') do
          p(class: 'eyebrow') { a(href: '/') { 'Sidereal Holidays' } }
          h1(class: 'booking__title') { 'Preparing your booking…' }
          p(class: 'booking__meta') do
            'The machine is deciding StartBooking. This page updates as soon as it has.'
          end
        end
      end

      def euros(amount) = "€#{amount.to_s.reverse.scan(/\d{1,3}/).join(',').reverse}"
      def pluralize(count, word) = "#{count} #{word}#{'s' unless count == 1}"
    end
  end
end
