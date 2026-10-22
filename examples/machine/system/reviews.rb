# frozen_string_literal: true

# A plain Sourced::Decider, not a machine: once a booking is confirmed it asks
# the traveller for a review, and takes one review per booking.
#
#   holidays.runtime.booking_confirmed ─reaction─▶ RequestReview ─▶ ReviewRequested
#   SubmitReview ─▶ ReviewSubmitted   (only once requested, and only once)
#   FlagReview ─▶ ReviewFlagged       (ReviewSummaries flags poor ratings)
class Reviews < Sourced::Decider
  partition_by :booking_id

  RequestReview = Sourced::Command.define('reviews.request_review') do
    attribute :booking_id, Sourced::Types::UUID::V4
  end

  SubmitReview = Sourced::Command.define('reviews.submit_review') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :rating, Sourced::Types::Integer[1..5]
    attribute :comment, Sourced::Types::String.default('')
  end

  FlagReview = Sourced::Command.define('reviews.flag_review') do
    attribute :booking_id, Sourced::Types::UUID::V4
  end

  ReviewRequested = Sourced::Event.define('reviews.review_requested') do
    attribute :booking_id, Sourced::Types::UUID::V4
  end

  ReviewSubmitted = Sourced::Event.define('reviews.review_submitted') do
    attribute :booking_id, Sourced::Types::UUID::V4
    attribute :rating, Sourced::Types::Integer[1..5]
    attribute :comment, Sourced::Types::String
  end

  ReviewFlagged = Sourced::Event.define('reviews.review_flagged') do
    attribute :booking_id, Sourced::Types::UUID::V4
  end

  context { { requested: false, submitted: false } }

  evolve ReviewRequested do |context, _evt|
    context[:requested] = true
  end

  evolve ReviewSubmitted do |context, _evt|
    context[:submitted] = true
  end

  command RequestReview do |context, cmd|
    event ReviewRequested, booking_id: cmd.payload.booking_id unless context[:requested]
  end

  command SubmitReview do |context, cmd|
    raise 'No review was requested for this booking' unless context[:requested]
    raise 'This booking has been reviewed already' if context[:submitted]

    event ReviewSubmitted, **cmd.payload.to_h
  end

  command FlagReview do |context, cmd|
    raise 'There is no review to flag' unless context[:submitted]

    event ReviewFlagged, booking_id: cmd.payload.booking_id
  end

  reaction HolidayBooking::BookingConfirmed do |_context, evt|
    dispatch RequestReview, booking_id: evt.payload.booking_id
  end
end
