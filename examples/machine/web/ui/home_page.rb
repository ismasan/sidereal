# frozen_string_literal: true

module UI
  # Where a booking starts: pick a destination and dates. Submitting sends
  # HolidayBooking::StartBooking, and the browser is sent to the new booking.
  class HomePage < Sidereal::Page
    path '/'

    def self.load(_params, _ctx) = new

    def view_template
      div(id: 'home-page') do
        div(class: 'sky', aria: { hidden: 'true' })

        main(class: 'welcome') do
          p(class: 'eyebrow') { 'Sidereal Holidays' }
          h1(class: 'welcome__title') { 'Plan a trip under other stars' }
          p(class: 'welcome__lead') do
            plain 'Each booking is a '
            code { 'Sourced::Machine' }
            plain ': a statechart whose flight, hotel and extras steps run in parallel, '
            plain 'with the hotel step nesting room and board. Watch it move as you go.'
          end

          command HolidayBooking::StartBooking.new(payload: { nights: 4, travellers: 2, depart_on: Date.today + 30 }),
                  class: 'start-form' do |f|
            div(class: 'start-form__field start-form__field--wide') do
              label(class: 'start-form__label', for: 'start-destination') { 'Destination' }
              select(id: 'start-destination', name: 'command[payload][destination]') do
                Catalogue::DESTINATIONS.each_value do |destination|
                  option(value: destination.code) { "#{destination.name}, #{destination.country}" }
                end
              end
            end
            labelled('Departing') { f.date_field :depart_on, min: Date.today.iso8601, aria: { label: 'Departing' } }
            labelled('Nights') { f.number_field :nights, min: 1, max: 21, aria: { label: 'Nights' } }
            labelled('Travellers') { f.number_field :travellers, min: 1, max: 6, aria: { label: 'Travellers' } }
            button(type: :submit, class: 'button button--primary') { 'Start booking' }
          end

          p(class: 'welcome__lead') do
            plain 'Bigger: '
            a(href: '/cross-post') { 'a whole cross-posting app' }
            plain ', described as a tree of machines.'
          end
        end
      end
    end

    private

    def labelled(text, &)
      div(class: 'start-form__field') do
        span(class: 'start-form__label', aria: { hidden: 'true' }) { text }
        yield
      end
    end
  end
end
