# frozen_string_literal: true

require 'sourced/testing/rspec'

RSpec.describe UI::BookingsPage do
  include Sourced::Testing::RSpec

  let(:trip) { { destination: 'lisbon', depart_on: Date.new(2027, 5, 1), nights: 4, travellers: 2 } }

  let(:context) do
    Class.new do
      def url(addr = nil, *) = addr.to_s
      def forms_codec = ::App.forms_codec
    end.new
  end

  def book(id, *commands)
    cmd = ->(klass, **payload) { klass.new(payload: { booking_id: id, **payload }) }
    messages = decided(HolidayBooking, { booking_id: id }, cmd.(HolidayBooking::StartBooking, **trip),
                       *commands.map { |klass, payload| cmd.(klass, **payload.to_h) })
    messages.reduce(with_reactor(BookingListing, booking_id: id)) { |gwt, msg| gwt.given(msg) }.then! { |_| }
  end

  def buttons(html, id) = html.scan(/<li class="option">.*?<\/li>/m).find { |row| row.include?(id) }.scan(/<button[^>]*>([^<]+)</).flatten

  before { Sidereal.config['db'][BookingListing::TABLE].delete }

  it "shows each booking's buttons from its machine configuration" do
    planning = '11111111-1111-4111-8111-111111111111'
    flight_chosen = '22222222-2222-4222-8222-222222222222'
    cancelled = '33333333-3333-4333-8333-333333333333'
    book(planning)
    book(flight_chosen, [HolidayBooking::ChooseFlight, { flight: 'SR2208' }])
    book(cancelled, [HolidayBooking::CancelBooking])

    html = described_class.load({}, nil).call(context:)

    expect(buttons(html, planning)).to eq(['Done with extras', 'Cancel'])
    expect(buttons(html, flight_chosen)).to eq(['Confirm flight', 'Done with extras', 'Cancel'])
    expect(buttons(html, cancelled)).to eq([])
    expect(html).to include('Planning', 'Cancelled')
  end
end
