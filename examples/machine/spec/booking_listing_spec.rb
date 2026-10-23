# frozen_string_literal: true

require 'sourced/testing/rspec'

RSpec.describe BookingListing do
  include Sourced::Testing::RSpec

  let(:id) { '6b1c0d7e-6a1f-4c55-9a43-2a3b9b5f8e10' }
  let(:trip) { { destination: 'lisbon', depart_on: Date.new(2027, 5, 1), nights: 4, travellers: 2 } }

  def cmd(klass, **payload) = klass.new(payload: { booking_id: id, **payload })
  def history(*commands) = decided(HolidayBooking, { booking_id: id }, cmd(HolidayBooking::StartBooking, **trip), *commands)

  def project(messages)
    messages.reduce(with_reactor(described_class, booking_id: id)) { |gwt, msg| gwt.given(msg) }.then! { |_| }
  end

  before { Sidereal.config['db'][described_class::TABLE].delete }

  it "keeps the booking's machine paths, as a loaded machine has them" do
    messages = history(
      cmd(HolidayBooking::ChooseFlight, flight: 'SR2208'),
      cmd(HolidayBooking::ChooseHotel, hotel: 'tejo-palace'),
      cmd(HolidayBooking::ChooseRoom, room: 'view')
    )
    project(messages)

    booking = HolidayBooking.new(booking_id: id).tap { |b| b.evolve(messages) }
    described_class.all => [record]

    expect(record).to have_attributes(booking_id: id, destination: 'lisbon', depart_on: Date.new(2027, 5, 1),
                                      nights: 4, travellers: 2, flight: 'SR2208', hotel: 'tejo-palace')
    expect(record.machine.paths).to eq(booking.machine.paths)
    expect(record.machine.available_commands).to eq(booking.available_commands)
    expect(record.machine.in?(:flight, HolidayBooking::FlightChosen)).to be(true)
  end

  it 'lists the most recently planned first, however recently updated' do
    other = '22222222-2222-4222-8222-222222222222'
    planned = history
    project(planned)
    project(decided(HolidayBooking, { booking_id: other },
                    HolidayBooking::StartBooking.new(payload: { booking_id: other, **trip })))
    project(decided(HolidayBooking, { booking_id: id }, cmd(HolidayBooking::CancelBooking), given: planned))

    expect(described_class.all.map(&:booking_id)).to eq([other, id])
  end

  it 'deletes every record on reset, for a replay to rebuild them' do
    project(history)

    described_class.on_reset
    expect(described_class.all).to be_empty
  end

  it 'lists what a finished booking accepts: nothing' do
    project(history(cmd(HolidayBooking::CancelBooking)))

    described_class.all => [{ machine: }]
    expect(machine.in?(HolidayBooking::BookingCancelled)).to be(true)
    expect(machine.available_commands).to be_empty
  end
end
