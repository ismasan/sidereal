# frozen_string_literal: true

module UI
  # Every booking, from the BookingListing read model. Each record carries a
  # read-only HolidayBooking configuration, so the buttons a row shows are the
  # commands that booking accepts now, without loading its history. Its forms
  # render inside with_machine, which raises for any it doesn't accept.
  class BookingsPage < Sidereal::Page
    path '/bookings'

    # The commands a row can send with the booking's id alone.
    ACTIONS = {
      HolidayBooking::ConfirmFlight => 'Confirm flight',
      HolidayBooking::FinishExtras => 'Done with extras',
      HolidayBooking::CancelBooking => 'Cancel'
    }.freeze

    STATUSES = {
      HolidayBooking::BookingConfirmed => 'Confirmed',
      HolidayBooking::BookingCancelled => 'Cancelled',
      HolidayBooking::HoldExpired => 'Hold expired',
      HolidayBooking::ItineraryReady => 'At checkout',
      HolidayBooking::BookingStarted => 'Planning'
    }.freeze

    # Reloads when the listing commits a change to any booking.
    on BookingListing

    def self.load(_params, _ctx) = new(BookingListing.all)

    # @param bookings [Array<BookingListing::Record>]
    def initialize(bookings)
      @bookings = bookings
    end

    def channel_name = 'bookings.*'

    def view_template
      div(id: 'bookings-page') do
        div(class: 'sky', aria: { hidden: 'true' })
        p(class: 'eyebrow') { a(href: '/') { 'Sidereal Holidays' } }
        h1(class: 'booking__title') { 'Bookings' }
        p(class: 'booking__meta') do
          plain 'Each row keeps the paths of its machine\'s active states, so its buttons are the commands that booking accepts now.'
        end

        if @bookings.empty?
          p { 'No bookings yet.' }
        else
          ul(class: 'options') { @bookings.each { |booking| render_booking(booking) } }
        end
      end
    end

    private

    def render_booking(booking)
      li(class: 'option') do
        div(class: 'option__body') do
          a(href: "/bookings/#{booking.booking_id}") { strong { destination_name(booking.destination) } }
          span(class: 'option__note') do
            "#{booking.depart_on&.strftime('%-d %b %Y')} · #{booking.nights} nights · #{booking.travellers} travellers"
          end
          span(class: 'option__tag') { status(booking.machine) }
        end
        div(class: 'option__actions') do
          with_machine(booking.machine) { render_actions(booking) }
        end
      end
    end

    def render_actions(booking)
      ACTIONS.each do |command_class, label|
        next unless booking.machine.available_commands.include?(command_class)

        command command_class, key: booking.booking_id, class: 'inline-form' do |f|
          f.payload_fields(booking_id: booking.booking_id)
          button(type: :submit, class: 'button') { label }
        end
      end
    end

    def status(machine) = STATUSES.find { |state, _| machine.in?(state) }&.last || 'Starting'

    def destination_name(code) = Catalogue::DESTINATIONS[code]&.name || code
  end
end
