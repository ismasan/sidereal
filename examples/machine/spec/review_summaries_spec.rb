# frozen_string_literal: true

require 'sourced/testing/rspec'

RSpec.describe ReviewSummaries do
  include Sourced::Testing::RSpec

  let(:id) { '6b1c0d7e-6a1f-4c55-9a43-2a3b9b5f8e10' }

  it 'flags a poor rating for follow-up' do
    with_reactor(ReviewSummaries, booking_id: id)
      .given(Reviews::ReviewRequested, booking_id: id)
      .given(Reviews::ReviewSubmitted, booking_id: id, rating: 2, comment: 'Noisy room')
      .then(Reviews::FlagReview, booking_id: id)
  end

  it 'leaves a good rating be' do
    with_reactor(ReviewSummaries, booking_id: id)
      .given(Reviews::ReviewRequested, booking_id: id)
      .given(Reviews::ReviewSubmitted, booking_id: id, rating: 5, comment: '')
      .then { |result| expect(result.messages).to be_empty }
  end
end
