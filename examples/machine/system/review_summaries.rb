# frozen_string_literal: true

# A read model of each booking's review: whether one was asked for, and its
# rating. A poor rating (2 stars or fewer) is flagged for follow-up.
class ReviewSummaries < Sourced::Projector::EventSourced
  partition_by :booking_id

  POOR = 2

  context { { status: nil, rating: nil } }

  evolve Reviews::ReviewRequested do |summary, _evt|
    summary[:status] = :requested
  end

  evolve Reviews::ReviewSubmitted do |summary, evt|
    summary[:status] = :submitted
    summary[:rating] = evt.payload.rating
  end

  reaction Reviews::ReviewSubmitted do |summary, evt|
    dispatch Reviews::FlagReview, booking_id: evt.payload.booking_id if summary[:rating] <= POOR
  end

  # Logged rather than stored: the example keeps no table for it.
  sync do |context:, **|
    Sourced.logger.info("review summary: #{context}")
  end
end
