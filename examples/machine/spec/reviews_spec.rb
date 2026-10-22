# frozen_string_literal: true

require 'sourced/testing/rspec'

RSpec.describe Reviews do
  include Sourced::Testing::RSpec

  let(:id) { '6b1c0d7e-6a1f-4c55-9a43-2a3b9b5f8e10' }

  it 'asks for a review once a booking is confirmed' do
    with_reactor(Reviews, booking_id: id)
      .when(HolidayBooking::BookingConfirmed, booking_id: id)
      .then(Reviews::RequestReview, booking_id: id)
  end

  it 'takes a review once requested' do
    with_reactor(Reviews, booking_id: id)
      .given(Reviews::ReviewRequested, booking_id: id)
      .when(Reviews::SubmitReview, booking_id: id, rating: 5, comment: 'Lovely')
      .then(Reviews::ReviewSubmitted, booking_id: id, rating: 5, comment: 'Lovely')
  end

  it "refuses a review that wasn't requested, or a second one" do
    expect {
      with_reactor(Reviews, booking_id: id)
        .when(Reviews::SubmitReview, booking_id: id, rating: 4)
        .then(Reviews::ReviewSubmitted, booking_id: id, rating: 4, comment: '')
    }.to raise_error(/No review was requested/)

    expect {
      with_reactor(Reviews, booking_id: id)
        .given(Reviews::ReviewRequested, booking_id: id)
        .given(Reviews::ReviewSubmitted, booking_id: id, rating: 4, comment: '')
        .when(Reviews::SubmitReview, booking_id: id, rating: 2)
        .then(Reviews::ReviewSubmitted, booking_id: id, rating: 2, comment: '')
    }.to raise_error(/reviewed already/)
  end
end
