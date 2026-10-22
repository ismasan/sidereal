# frozen_string_literal: true

# A read model of each booking, from HolidayBooking's events: the trip and
# what's been chosen for it (its data events), and how it ended (its state
# events, appended as the machine moves).
class BookingSummaries < Sourced::Projector::EventSourced
  partition_by :booking_id

  context { { status: :planning, destination: nil, depart_on: nil, flight: nil, hotel: nil, payment: nil } }

  evolve HolidayBooking::TripPlanned do |summary, evt|
    summary[:destination] = evt.payload.destination
    summary[:depart_on] = evt.payload.depart_on
  end

  evolve HolidayBooking::FlightSelected do |summary, evt|
    summary[:flight] = evt.payload.flight
  end

  evolve HolidayBooking::HotelSelected do |summary, evt|
    summary[:hotel] = evt.payload.hotel
  end

  evolve HolidayBooking::PaymentCaptured do |summary, evt|
    summary[:payment] = evt.payload.reference
  end

  evolve HolidayBooking::BookingConfirmed do |summary, _evt|
    summary[:status] = :confirmed
  end

  evolve HolidayBooking::BookingCancelled do |summary, _evt|
    summary[:status] = :cancelled
  end

  evolve HolidayBooking::HoldExpired do |summary, _evt|
    summary[:status] = :expired
  end

  # Logged rather than stored: the example keeps no table for it.
  sync do |context:, **|
    Sourced.logger.info("booking summary: #{context}")
  end
end
