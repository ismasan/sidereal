# frozen_string_literal: true


RSpec.describe UI::Booking::Page do

  let(:id) { '6b1c0d7e-6a1f-4c55-9a43-2a3b9b5f8e10' }
  let(:trip) { { destination: 'lisbon', depart_on: Date.new(2027, 5, 1), nights: 4, travellers: 2 } }

  def cmd(klass, **payload) = klass.new(payload: { booking_id: id, **payload })

  let(:context) do
    Class.new do
      def url(addr = nil, *) = addr.to_s
      def forms_codec = ::App.forms_codec
    end.new
  end

  it 'renders only forms the booking accepts, at every step of its history' do
    messages = decided(
      HolidayBooking, { booking_id: id },
      cmd(HolidayBooking::StartBooking, **trip),
      cmd(HolidayBooking::ChooseFlight, flight: 'TP1351'),
      cmd(HolidayBooking::ConfirmFlight),
      cmd(HolidayBooking::ChooseHotel, hotel: 'tejo-palace'),
      cmd(HolidayBooking::ChooseRoom, room: 'view'),
      cmd(HolidayBooking::ChooseBoard, board: 'breakfast'),
      cmd(HolidayBooking::FinishExtras)
    )

    (1..messages.size).each do |step|
      history = UI::Booking::History.new(booking_id: id, messages:, step:)
      expect { described_class.new(history).call(context:) }.not_to raise_error
    end
  end
end
