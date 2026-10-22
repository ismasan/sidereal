# frozen_string_literal: true

require 'sourced/testing/rspec'

RSpec.describe BookingSummaries do
  include Sourced::Testing::RSpec

  let(:id) { '6b1c0d7e-6a1f-4c55-9a43-2a3b9b5f8e10' }

  def moved_to(state) = moved(HolidayBooking, 'Pay', from: 'itinerary_ready', to: state, booking_id: id)

  it 'sums up a booking from its data and state events' do
    with_reactor(described_class, booking_id: id)
      .given(HolidayBooking::TripPlanned, booking_id: id, destination: 'lisbon', depart_on: Date.new(2027, 5, 1), nights: 4, travellers: 2)
      .given(HolidayBooking::FlightSelected, booking_id: id, flight: 'SR2208')
      .given(HolidayBooking::PaymentCaptured, booking_id: id, reference: 'pay_1', last4: '4242')
      .given(moved_to('booking_confirmed'))
      .then! do |result|
        expect(result.context).to include(status: :confirmed, destination: 'lisbon', flight: 'SR2208', payment: 'pay_1')
      end
  end
end
