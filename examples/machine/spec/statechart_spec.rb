# frozen_string_literal: true

RSpec.describe UI::Components::Statechart do
  let(:id) { '6b1c0d7e-6a1f-4c55-9a43-2a3b9b5f8e10' }

  def render(chart) = described_class.new(chart).call

  it 'draws the definition, with nothing active' do
    svg = render(HolidayBooking.to_h)

    expect(svg).to include('id="sc-holidays-booking_started"', 'id="sc-holidays-room_chosen"', '>ChooseBoard<')
    expect(svg).not_to include('is-active')
  end

  it "lights an instance's active checkpoints and the transitions they accept" do
    booking = HolidayBooking.new(booking_id: id)
    booking.evolve([
      HolidayBooking::BookingStarted.new(
        payload: { booking_id: id, destination: 'lisbon', depart_on: Date.new(2027, 5, 1), nights: 4, travellers: 2 }
      ),
      HolidayBooking::FlightChosen.new(payload: { booking_id: id, flight: 'SR2208' })
    ])
    svg = render(booking.to_h)

    expect(svg).to match(/class="statechart__node statechart__node--atomic is-active" id="sc-holidays-flight_chosen"/)
    expect(svg).to match(/statechart__edge--live is-live"><path[^>]*><\/path><text[^>]*>ConfirmFlight</)
    expect(svg).not_to match(/is-active" id="sc-holidays-itinerary_ready"/)
  end
end
