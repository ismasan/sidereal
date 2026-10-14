# frozen_string_literal: true

require 'sourced/testing/rspec'

RSpec.describe HolidayBooking do
  include Sourced::Testing::RSpec

  let(:id) { '6b1c0d7e-6a1f-4c55-9a43-2a3b9b5f8e10' }

  let(:started) do
    HolidayBooking::BookingStarted.new(
      payload: { booking_id: id, destination: 'lisbon', depart_on: Date.new(2027, 5, 1), nights: 4, travellers: 2 }
    )
  end

  def evt(klass, **payload) = klass.new(payload: { booking_id: id, **payload })

  def configuration(*history)
    instance = HolidayBooking.new(booking_id: id)
    instance.evolve(history)
    instance.machine.value
  end

  it 'starts a booking from the command' do
    with_reactor(HolidayBooking, booking_id: id)
      .when(HolidayBooking::StartBooking, booking_id: id, destination: 'lisbon',
                                          depart_on: Date.new(2027, 5, 1), nights: 4, travellers: 2)
      .then(started)
  end

  it 'runs the flight, hotel and extras regions in parallel once started' do
    expect(configuration(started)).to eq(
      HolidayBooking::BookingStarted => { flight: :initial, hotel: :initial, extras: :initial }
    )
  end

  it 'nests room and board regions inside the chosen hotel' do
    expect(configuration(started, evt(HolidayBooking::HotelChosen, hotel: 'tejo-palace'))).to eq(
      HolidayBooking::BookingStarted => {
        flight: :initial,
        hotel: { HolidayBooking::HotelChosen => { room: :initial, board: :initial } },
        extras: :initial
      }
    )
  end

  it 'confirms the hotel in the same decision that completes its last nested region' do
    with_reactor(HolidayBooking, booking_id: id)
      .given(started)
      .and(evt(HolidayBooking::HotelChosen, hotel: 'tejo-palace'))
      .and(evt(HolidayBooking::RoomChosen, room: 'view'))
      .when(HolidayBooking::ChooseBoard, booking_id: id, board: 'breakfast')
      .then(evt(HolidayBooking::BoardChosen, board: 'breakfast'), evt(HolidayBooking::HotelConfirmed))
  end

  it 'starts room and board over when another hotel is chosen' do
    history = [
      started,
      evt(HolidayBooking::HotelChosen, hotel: 'tejo-palace'),
      evt(HolidayBooking::RoomChosen, room: 'suite'),
      evt(HolidayBooking::HotelChosen, hotel: 'alfama-azul')
    ]

    expect(configuration(*history).dig(HolidayBooking::BookingStarted, :hotel)).to eq(
      HolidayBooking::HotelChosen => { room: :initial, board: :initial }
    )
  end

  it 'records extras as data, toggling them on and off' do
    with_reactor(HolidayBooking, booking_id: id)
      .given(started)
      .and(evt(HolidayBooking::ExtraAdded, extra: 'insurance'))
      .when(HolidayBooking::ToggleExtra, booking_id: id, extra: 'insurance')
      .then(evt(HolidayBooking::ExtraRemoved, extra: 'insurance'))
  end

  it 'moves to checkout once every region is final' do
    with_reactor(HolidayBooking, booking_id: id)
      .given(started)
      .and(evt(HolidayBooking::FlightChosen, flight: 'SR2208'))
      .and(evt(HolidayBooking::FlightConfirmed))
      .and(evt(HolidayBooking::HotelChosen, hotel: 'tejo-palace'))
      .and(evt(HolidayBooking::RoomChosen, room: 'view'))
      .and(evt(HolidayBooking::BoardChosen, board: 'breakfast'))
      .and(evt(HolidayBooking::HotelConfirmed))
      .when(HolidayBooking::FinishExtras, booking_id: id)
      .then(evt(HolidayBooking::ExtrasChosen), evt(HolidayBooking::ItineraryReady))
  end

  it 'leaves every region when cancelled' do
    with_reactor(HolidayBooking, booking_id: id)
      .given(started)
      .and(evt(HolidayBooking::HotelChosen, hotel: 'tejo-palace'))
      .when(HolidayBooking::CancelBooking, booking_id: id)
      .then(evt(HolidayBooking::BookingCancelled))
  end

  context 'at checkout' do
    let(:ready) { evt(HolidayBooking::ItineraryReady) }

    it 'holds the itinerary, expiring it after HOLD_SECONDS' do
      with_reactor(HolidayBooking, booking_id: id)
        .given(started)
        .when(ready)
        .then do |result|
          expire = result.messages.find { |m| m.is_a?(HolidayBooking::ExpireHold) }
          expect(expire.payload.booking_id).to eq(id)
          expect(expire.created_at).to be_within(1).of(ready.created_at + HolidayBooking::HOLD_SECONDS)
        end
    end

    it 'stays at checkout when the card is declined' do
      with_reactor(HolidayBooking, booking_id: id)
        .given(started)
        .and(ready)
        .when(HolidayBooking::Pay, booking_id: id, card_number: '4000 0000 0000 0000')
        .then(evt(HolidayBooking::PaymentDeclined, last4: '0000', reason: 'Your card was declined. Try another one.'))
    end

    it 'confirms the booking when the card is charged' do
      with_reactor(HolidayBooking, booking_id: id)
        .given(started)
        .and(ready)
        .when(HolidayBooking::Pay, booking_id: id, card_number: '4242 4242 4242 4242')
        .then do |result|
          expect(result.messages.size).to eq(1)
          confirmed = result.messages.first
          expect(confirmed).to be_a(HolidayBooking::BookingConfirmed)
          expect(confirmed.payload.last4).to eq('4242')
          expect(confirmed.payload.reference).to match(/\ASR-[A-Z0-9]{6}\z/)
        end
    end

    it 'refuses to pay before checkout' do
      instance = HolidayBooking.new(booking_id: id)
      instance.evolve([started])

      expect(instance.handles_command?(HolidayBooking::Pay.new(payload: { booking_id: id, card_number: '4242424242424242' })))
        .to be(false)
    end
  end
end
