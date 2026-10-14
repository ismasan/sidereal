# frozen_string_literal: true

require 'securerandom'

# A holiday booking as a statechart. Starting a booking enters BookingStarted,
# which runs three regions in parallel — the flight, the hotel and the extras —
# in whatever order the traveller fills them in. The hotel region nests two
# more (room and board). Each region ends at a final checkpoint, and once all
# of them have, the booking moves on to checkout by itself (`done`), where the
# itinerary is held for HOLD_SECONDS before it expires.
#
#   initial ─StartBooking─▶ BookingStarted ─────────────────done─▶ ItineraryReady ─Pay─▶ BookingConfirmed
#                           ├ flight: ChooseFlight ▶ FlightChosen ▶ FlightConfirmed      ├─ExpireHold─▶ HoldExpired
#                           ├ hotel:  ChooseHotel ▶ HotelChosen ─done─▶ HotelConfirmed   └─Cancel─▶ BookingCancelled
#                           │                       ├ room:  ChooseRoom ▶ RoomChosen
#                           │                       └ board: ChooseBoard ▶ BoardChosen
#                           └ extras: ToggleExtra (data) … FinishExtras ▶ ExtrasChosen
#
# Every checkpoint is an event the machine appends, so the booking's position
# and its data both come from its history.
class HolidayBooking < Sourced::Machine
  partition_by :booking_id

  # How long checkout holds the itinerary before it expires. Set HOLD_SECONDS
  # in the environment to watch it expire sooner.
  HOLD_SECONDS = Integer(ENV.fetch('HOLD_SECONDS', 180))

  # ---- Commands ----

  StartBooking = Sourced::Command.define('holidays.start_booking') do
    attribute :booking_id, Sourced::Types::AutoUUID
    attribute :destination, Sourced::Types::String.options(Catalogue::DESTINATIONS.keys)
    attribute :depart_on, Sourced::Types::Date
    attribute :nights, Sourced::Types::Integer[1..21]
    attribute :travellers, Sourced::Types::Integer[1..6]
  end

  ChooseFlight = Sourced::Command.define('holidays.choose_flight') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :flight, Sourced::Types::String.options(Catalogue.flight_codes)
  end

  ConfirmFlight = Sourced::Command.define('holidays.confirm_flight') do
    attribute :booking_id, Sourced::Types::UUID::V4
  end

  ChooseHotel = Sourced::Command.define('holidays.choose_hotel') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :hotel, Sourced::Types::String.options(Catalogue.hotel_codes)
  end

  ChooseRoom = Sourced::Command.define('holidays.choose_room') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :room, Sourced::Types::String.options(Catalogue::ROOMS.keys)
  end

  ChooseBoard = Sourced::Command.define('holidays.choose_board') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :board, Sourced::Types::String.options(Catalogue::BOARDS.keys)
  end

  ToggleExtra = Sourced::Command.define('holidays.toggle_extra') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :extra, Sourced::Types::String.options(Catalogue::EXTRAS.keys)
  end

  FinishExtras = Sourced::Command.define('holidays.finish_extras') do
    attribute :booking_id, Sourced::Types::UUID::V4
  end

  Pay = Sourced::Command.define('holidays.pay') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :card_number, (Sourced::Types::String.check('Enter a card number: 12 to 19 digits') do |number|
      number.delete(' ').match?(/\A\d{12,19}\z/)
    end)
  end

  CancelBooking = Sourced::Command.define('holidays.cancel_booking') do
    attribute :booking_id, Sourced::Types::UUID::V4
  end

  # Dispatched by the checkout timer, never by a browser.
  ExpireHold = Sourced::Command.define('holidays.expire_hold') do
    attribute :booking_id, Sourced::Types::UUID::V4
  end

  # ---- Events ----

  BookingStarted = Sourced::Event.define('holidays.booking_started') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :destination, Sourced::Types::String
    attribute :depart_on, Sourced::Types::Date
    attribute :nights, Sourced::Types::Integer
    attribute :travellers, Sourced::Types::Integer
  end

  FlightChosen = Sourced::Event.define('holidays.flight_chosen') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :flight, Sourced::Types::String
  end

  FlightConfirmed = Sourced::Event.define('holidays.flight_confirmed') do
    attribute :booking_id, Sourced::Types::UUID::V4
  end

  HotelChosen = Sourced::Event.define('holidays.hotel_chosen') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :hotel, Sourced::Types::String
  end

  RoomChosen = Sourced::Event.define('holidays.room_chosen') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :room, Sourced::Types::String
  end

  BoardChosen = Sourced::Event.define('holidays.board_chosen') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :board, Sourced::Types::String
  end

  HotelConfirmed = Sourced::Event.define('holidays.hotel_confirmed') do
    attribute :booking_id, Sourced::Types::UUID::V4
  end

  # Data: they change the extras, not the machine's position.
  ExtraAdded = Sourced::Event.define('holidays.extra_added') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :extra, Sourced::Types::String
  end

  ExtraRemoved = Sourced::Event.define('holidays.extra_removed') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :extra, Sourced::Types::String
  end

  ExtrasChosen = Sourced::Event.define('holidays.extras_chosen') do
    attribute :booking_id, Sourced::Types::UUID::V4
  end

  ItineraryReady = Sourced::Event.define('holidays.itinerary_ready') do
    attribute :booking_id, Sourced::Types::UUID::V4
  end

  # Data: a declined card leaves checkout where it is, hold timer included.
  PaymentDeclined = Sourced::Event.define('holidays.payment_declined') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :last4, Sourced::Types::String
    attribute :reason, Sourced::Types::String
  end

  BookingConfirmed = Sourced::Event.define('holidays.booking_confirmed') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :reference, Sourced::Types::String
    attribute :last4, Sourced::Types::String
  end

  BookingCancelled = Sourced::Event.define('holidays.booking_cancelled') do
    attribute :booking_id, Sourced::Types::UUID::V4
  end

  HoldExpired = Sourced::Event.define('holidays.hold_expired') do
    attribute :booking_id, Sourced::Types::UUID::V4
  end

  # ---- Domain state ----

  # What the traveller has picked so far. The machine's position (which step
  # each region is at) is kept by the machine itself: see #machine.
  class Trip
    attr_accessor :booking_id, :destination, :depart_on, :nights, :travellers,
                  :flight, :hotel, :room, :board, :hold_until, :declined, :reference
    attr_reader :extras

    def initialize
      @extras = []
    end

    def started? = !destination.nil?

    def toggle(extra)
      extras.include?(extra) ? extras.delete(extra) : extras << extra
    end

    def destination_info = destination && Catalogue.destination(destination)
    def flight_info = flight && Catalogue.flight(flight)
    def hotel_info = hotel && Catalogue.hotel(hotel)
    def room_info = room && Catalogue::ROOMS[room]
    def board_info = board && Catalogue::BOARDS[board]
    def return_on = depart_on && depart_on + nights

    # Line items for what's been picked so far: [label, amount].
    def lines
      items = []
      items << ["Flights × #{travellers}", flight_info.price * travellers] if flight_info
      items << ["#{hotel_info.name}, #{nights} nights", hotel_info.nightly * nights] if hotel_info
      items << [room_info.name, room_info.price * nights] if room_info&.price&.positive?
      items << [board_info.name, board_info.price * travellers * nights] if board_info&.price&.positive?
      extras.each do |code|
        extra = Catalogue::EXTRAS.fetch(code)
        items << [extra.name, Catalogue::PER_PERSON_EXTRAS.include?(code) ? extra.price * travellers : extra.price]
      end
      items
    end

    def total = lines.sum(&:last)
  end

  state do
    Trip.new
  end

  before_evolve do |trip, evt|
    trip.booking_id = evt.payload.booking_id
  end

  evolve BookingStarted do |trip, evt|
    trip.destination = evt.payload.destination
    trip.depart_on = evt.payload.depart_on
    trip.nights = evt.payload.nights
    trip.travellers = evt.payload.travellers
  end

  evolve FlightChosen do |trip, evt|
    trip.flight = evt.payload.flight
  end

  # Choosing another hotel re-enters HotelChosen, which restarts its room and
  # board regions: the earlier picks were for the other hotel.
  evolve HotelChosen do |trip, evt|
    trip.hotel = evt.payload.hotel
    trip.room = nil
    trip.board = nil
  end

  evolve RoomChosen do |trip, evt|
    trip.room = evt.payload.room
  end

  evolve BoardChosen do |trip, evt|
    trip.board = evt.payload.board
  end

  evolve ExtraAdded do |trip, evt|
    trip.toggle(evt.payload.extra)
  end

  evolve ExtraRemoved do |trip, evt|
    trip.toggle(evt.payload.extra)
  end

  evolve ItineraryReady do |trip, evt|
    trip.hold_until = evt.created_at + HOLD_SECONDS
  end

  evolve PaymentDeclined do |trip, evt|
    trip.declined = evt.payload.reason
  end

  evolve BookingConfirmed do |trip, evt|
    trip.reference = evt.payload.reference
  end

  # ---- The statechart ----

  initial do
    command StartBooking => BookingStarted
  end

  checkpoint BookingStarted do
    command CancelBooking => BookingCancelled

    region :flight do
      initial do
        command ChooseFlight => FlightChosen
      end

      checkpoint FlightChosen do
        command ChooseFlight => FlightChosen
        command ConfirmFlight => FlightConfirmed
      end

      final FlightConfirmed
    end

    region :hotel do
      initial do
        command ChooseHotel => HotelChosen
      end

      checkpoint HotelChosen do
        command ChooseHotel => HotelChosen

        region :room do
          initial do
            command ChooseRoom => RoomChosen
          end

          final RoomChosen
        end

        region :board do
          initial do
            command ChooseBoard => BoardChosen
          end

          final BoardChosen
        end

        done HotelConfirmed
      end

      final HotelConfirmed
    end

    region :extras do
      initial do
        command ToggleExtra do |trip, cmd|
          extra = cmd.payload.extra
          event(trip.extras.include?(extra) ? ExtraRemoved : ExtraAdded, extra:)
        end

        command FinishExtras => ExtrasChosen
      end

      final ExtrasChosen
    end

    done ItineraryReady
  end

  checkpoint ItineraryReady do
    after(HOLD_SECONDS) do |_trip, _evt|
      dispatch ExpireHold
    end

    # A card ending in 0000 is declined, any other is charged.
    command Pay => BookingConfirmed | nil do |_trip, cmd|
      card = cmd.payload.card_number.delete(' ')
      if card.end_with?('0000')
        event PaymentDeclined, last4: card[-4..], reason: 'Your card was declined. Try another one.'
      else
        event BookingConfirmed, last4: card[-4..], reference: "SR-#{SecureRandom.alphanumeric(6).upcase}"
      end
    end

    command ExpireHold => HoldExpired
    command CancelBooking => BookingCancelled
  end

  final BookingConfirmed
  final BookingCancelled
  final HoldExpired
end
