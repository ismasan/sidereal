# frozen_string_literal: true

RSpec.describe UI::Components::Statechart do
  let(:id) { '6b1c0d7e-6a1f-4c55-9a43-2a3b9b5f8e10' }

  def render(chart) = described_class.new(chart).call
  def cmd(klass, **payload) = klass.new(payload: { booking_id: id, **payload })

  it 'draws the definition, with nothing active' do
    svg = render(HolidayBooking.to_h)

    expect(svg).to include(
      'id="sc-booking_started"',
      'id="sc-booking_started-hotel-hotel_chosen-room-room_chosen"',
      '>ChooseBoard<'
    )
    expect(svg).not_to include('is-active')
  end

  it "lights an instance's active checkpoints and the transitions they accept" do
    booking = HolidayBooking.new(booking_id: id)
    booking.evolve(decided(
      HolidayBooking, { booking_id: id },
      cmd(HolidayBooking::StartBooking, destination: 'lisbon', depart_on: Date.new(2027, 5, 1), nights: 4, travellers: 2),
      cmd(HolidayBooking::ChooseFlight, flight: 'SR2208')
    ))
    svg = render(booking.to_h)

    expect(svg).to match(
      /class="statechart__node statechart__node--atomic is-active" id="sc-booking_started-flight-flight_chosen"/
    )
    expect(svg).to match(/statechart__edge--live is-live"><path[^>]*><\/path><text[^>]*>ConfirmFlight</)
    expect(svg).not_to match(/is-active" id="sc-itinerary_ready"/)
  end
end
