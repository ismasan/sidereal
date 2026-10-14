# frozen_string_literal: true

module UI
  # A booking's messages, commands and events alike, in log order, and the
  # HolidayBooking machine evolved from the first +step+ of them: the booking as
  # it is now (+step+ nil), or as it was after any message in its history.
  class BookingHistory
    attr_reader :booking_id, :messages, :step

    def self.load(booking_id, step: nil)
      types = (HolidayBooking.handled_messages_for_evolve + HolidayBooking.handled_commands).map(&:type).uniq
      messages = Sourced.store.read_partition({ booking_id: }, handled_types: types).messages
      new(booking_id:, messages:, step:)
    end

    def initialize(booking_id:, messages:, step: nil)
      @booking_id = booking_id
      @messages = messages
      @step = step
    end

    def live? = step.nil?

    def current_step = step || messages.size

    # The machine at #current_step. Commands are in the history for the feed;
    # evolving skips them, as the machine only evolves its events.
    def booking
      @booking ||= HolidayBooking.new(booking_id:).tap { |b| b.evolve(messages.first(current_step)) }
    end
  end
end
