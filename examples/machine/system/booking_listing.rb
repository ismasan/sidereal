# frozen_string_literal: true

require 'json'

# Every booking, for a listing: the trip, what's been chosen for it, and the
# HolidayBooking machine's configuration, kept as the paths of its active
# states. Each state event's exited and entered paths update them, so the
# listing knows what each booking accepts without loading its history (see
# Record#machine).
class BookingListing < Sourced::Projector::StateStored
  partition_by :booking_id

  dep :db

  TABLE = :booking_listings

  # A listed booking. +machine+ is a read-only HolidayBooking configuration.
  Record = Data.define(:booking_id, :destination, :depart_on, :nights, :travellers, :flight, :hotel, :machine,
                       :created_at, :updated_at)

  # Most recently planned first, so updating a booking doesn't move it.
  #
  # @return [Array<Record>]
  def self.all(db: Sidereal.config['db'])
    db[TABLE].reverse(:created_at, :booking_id).map do |row|
      Record.new(**row, machine: HolidayBooking.configuration(JSON.parse(row[:machine])))
    end
  end

  # Called by Sourced.reset_consumer_group(BookingListing), which replays every
  # booking from the start: the records are rebuilt from scratch.
  def self.on_reset(db: Sidereal.config['db'])
    db[TABLE].delete
  end

  context do
    { booking_id: nil, destination: nil, depart_on: nil, nights: nil, travellers: nil, flight: nil, hotel: nil, machine: [],
      created_at: nil }
  end

  load_context do |partition_values|
    row = db[TABLE].where(booking_id: partition_values[:booking_id]).first
    row && row.except(:updated_at).merge(machine: JSON.parse(row[:machine]))
  end

  evolve HolidayBooking::TripPlanned do |booking, evt|
    booking[:booking_id] = evt.payload.booking_id
    booking[:destination] = evt.payload.destination
    booking[:depart_on] = evt.payload.depart_on
    booking[:nights] = evt.payload.nights
    booking[:travellers] = evt.payload.travellers
    booking[:created_at] = evt.created_at
  end

  evolve HolidayBooking::FlightSelected do |booking, evt|
    booking[:flight] = evt.payload.flight
  end

  evolve HolidayBooking::HotelSelected do |booking, evt|
    booking[:hotel] = evt.payload.hotel
  end

  HolidayBooking.transition_classes.each do |klass|
    evolve(klass) do |booking, evt|
      booking[:booking_id] ||= evt.payload.booking_id
      booking[:machine] = (booking[:machine] - evt.payload.exited) | evt.payload.entered
    end
  end

  sync do |context:, **|
    next unless context[:created_at]

    db[TABLE].insert_conflict(:replace).insert(**context, machine: JSON.generate(context[:machine]), updated_at: Time.now)
  end
end
