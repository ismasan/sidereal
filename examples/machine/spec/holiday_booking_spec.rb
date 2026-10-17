# frozen_string_literal: true

require 'sourced/testing/rspec'

RSpec.describe HolidayBooking do
  include Sourced::Testing::RSpec

  let(:id) { '6b1c0d7e-6a1f-4c55-9a43-2a3b9b5f8e10' }
  let(:trip) { { destination: 'lisbon', depart_on: Date.new(2027, 5, 1), nights: 4, travellers: 2 } }

  def cmd(klass, **payload) = klass.new(payload: { booking_id: id, **payload })
  def evt(klass, **payload) = klass.new(payload: { booking_id: id, **payload })
  def move(trigger, **) = moved(HolidayBooking, "holidays.#{trigger}", booking_id: id, **)

  def history(*commands) = decided(HolidayBooking, { booking_id: id }, cmd(HolidayBooking::StartBooking, **trip), *commands)
  def given(*history) = history.reduce(with_reactor(HolidayBooking, booking_id: id)) { |gwt, msg| gwt.given(msg) }

  def configuration(*commands)
    instance = HolidayBooking.new(booking_id: id)
    instance.evolve(history(*commands))
    instance.machine.value
  end

  it 'starts a booking from the command, with the trip as data' do
    with_reactor(HolidayBooking, booking_id: id)
      .when(HolidayBooking::StartBooking, booking_id: id, **trip)
      .then(
        evt(HolidayBooking::TripPlanned, **trip),
        move('start_booking', from: 'initial', to: 'booking_started')
      )
  end

  it 'runs the flight, hotel and extras regions in parallel once started' do
    expect(configuration).to eq(
      HolidayBooking::BookingStarted => { flight: :initial, hotel: :initial, extras: :initial }
    )
  end

  it 'nests room and board regions inside the chosen hotel' do
    expect(configuration(cmd(HolidayBooking::ChooseHotel, hotel: 'tejo-palace'))).to eq(
      HolidayBooking::BookingStarted => {
        flight: :initial,
        hotel: { HolidayBooking::HotelChosen => { room: :initial, board: :initial } },
        extras: :initial
      }
    )
  end

  it 'confirms the hotel in the same decision that completes its last nested region' do
    given(*history(cmd(HolidayBooking::ChooseHotel, hotel: 'tejo-palace'), cmd(HolidayBooking::ChooseRoom, room: 'view')))
      .when(HolidayBooking::ChooseBoard, booking_id: id, board: 'breakfast')
      .then(
        evt(HolidayBooking::BoardSelected, board: 'breakfast'),
        move('choose_board', from: 'booking_started.hotel.hotel_chosen.board.initial',
                             to: 'booking_started.hotel.hotel_chosen.board.board_chosen'),
        moved(HolidayBooking, 'done', booking_id: id,
                                      from: 'booking_started.hotel.hotel_chosen', to: 'booking_started.hotel.hotel_confirmed',
                                      exited: %w[
                                        booking_started.hotel.hotel_chosen.room.room_chosen
                                        booking_started.hotel.hotel_chosen.board.board_chosen
                                        booking_started.hotel.hotel_chosen
                                      ])
      )
  end

  it 'starts room and board over when another hotel is chosen' do
    given(*history(cmd(HolidayBooking::ChooseHotel, hotel: 'tejo-palace'), cmd(HolidayBooking::ChooseRoom, room: 'suite')))
      .when(HolidayBooking::ChooseHotel, booking_id: id, hotel: 'alfama-azul')
      .then(
        evt(HolidayBooking::HotelSelected, hotel: 'alfama-azul'),
        move('choose_hotel', from: 'booking_started.hotel.hotel_chosen', to: 'booking_started.hotel.hotel_chosen',
                             exited: %w[booking_started.hotel.hotel_chosen.room.room_chosen booking_started.hotel.hotel_chosen])
      )

    configuration = configuration(
      cmd(HolidayBooking::ChooseHotel, hotel: 'tejo-palace'),
      cmd(HolidayBooking::ChooseRoom, room: 'suite'),
      cmd(HolidayBooking::ChooseHotel, hotel: 'alfama-azul')
    )
    expect(configuration.dig(HolidayBooking::BookingStarted, :hotel)).to eq(
      HolidayBooking::HotelChosen => { room: :initial, board: :initial }
    )
  end

  it 'records extras as data, toggling them on and off' do
    given(*history(cmd(HolidayBooking::ToggleExtra, extra: 'insurance')))
      .when(HolidayBooking::ToggleExtra, booking_id: id, extra: 'insurance')
      .then(evt(HolidayBooking::ExtraRemoved, extra: 'insurance'))
  end

  it 'moves to checkout once every region is final' do
    chosen = history(
      cmd(HolidayBooking::ChooseFlight, flight: 'SR2208'),
      cmd(HolidayBooking::ConfirmFlight),
      cmd(HolidayBooking::ChooseHotel, hotel: 'tejo-palace'),
      cmd(HolidayBooking::ChooseRoom, room: 'view'),
      cmd(HolidayBooking::ChooseBoard, board: 'breakfast')
    )

    given(*chosen)
      .when(HolidayBooking::FinishExtras, booking_id: id)
      .then(
        move('finish_extras', from: 'booking_started.extras.initial', to: 'booking_started.extras.extras_chosen'),
        moved(HolidayBooking, 'done', booking_id: id, from: 'booking_started', to: 'itinerary_ready',
                                      exited: %w[
                                        booking_started.flight.flight_confirmed
                                        booking_started.hotel.hotel_confirmed
                                        booking_started.extras.extras_chosen
                                        booking_started
                                      ])
      )
  end

  it 'leaves every region when cancelled' do
    given(*history(cmd(HolidayBooking::ChooseHotel, hotel: 'tejo-palace')))
      .when(HolidayBooking::CancelBooking, booking_id: id)
      .then(move('cancel_booking', from: 'booking_started', to: 'booking_cancelled',
                                   exited: %w[booking_started.hotel.hotel_chosen booking_started]))
  end

  context 'at checkout' do
    let(:checkout) do
      history(
        cmd(HolidayBooking::ChooseFlight, flight: 'SR2208'),
        cmd(HolidayBooking::ConfirmFlight),
        cmd(HolidayBooking::ChooseHotel, hotel: 'tejo-palace'),
        cmd(HolidayBooking::ChooseRoom, room: 'view'),
        cmd(HolidayBooking::ChooseBoard, board: 'breakfast'),
        cmd(HolidayBooking::FinishExtras)
      )
    end

    it 'holds the itinerary, expiring it after HOLD_SECONDS' do
      *before, ready = checkout
      expect(ready.payload.target).to eq('itinerary_ready')

      given(*before)
        .when(ready)
        .then do |result|
          expire = result.messages.find { HolidayBooking::ExpireHold === it }
          expect(expire.payload.booking_id).to eq(id)
          expect(expire.created_at).to be_within(1).of(ready.created_at + HolidayBooking::HOLD_SECONDS)
        end
    end

    it 'stays at checkout when the card is declined' do
      given(*checkout)
        .when(HolidayBooking::Pay, booking_id: id, card_number: '4000 0000 0000 0000')
        .then(evt(HolidayBooking::PaymentDeclined, last4: '0000', reason: 'Your card was declined. Try another one.'))
    end

    it 'confirms the booking when the card is charged' do
      given(*checkout)
        .when(HolidayBooking::Pay, booking_id: id, card_number: '4242 4242 4242 4242')
        .then do |result|
          captured, confirmed = result.messages
          expect(result.messages.size).to eq(2)
          expect(captured).to be_a(HolidayBooking::PaymentCaptured)
          expect(captured.payload.last4).to eq('4242')
          expect(captured.payload.reference).to match(/\ASR-[A-Z0-9]{6}\z/)
          expect(confirmed.payload).to eq(move('pay', from: 'itinerary_ready', to: 'booking_confirmed', exited: %w[itinerary_ready]).payload)
        end
    end

    it 'refuses to pay before checkout' do
      instance = HolidayBooking.new(booking_id: id)
      instance.evolve(history)

      expect(instance.handles_command?(cmd(HolidayBooking::Pay, card_number: '4242424242424242'))).to be(false)
    end
  end

  # The machine decides any Pay it's given: a card number is checked when the
  # command is built, which is where a browser's command is refused.
  describe 'a card number' do
    def pay(card_number) = cmd(HolidayBooking::Pay, card_number:)

    it 'takes 12 to 19 digits, dropping the spaces people type' do
      expect(pay('4242 4242 4242 4242')).to be_valid
      expect(pay('4242 4242 4242 4242').payload.card_number).to eq('4242424242424242')
      expect(pay('424242424242')).to be_valid
    end

    it 'refuses anything else' do
      expect(pay('4242')).not_to be_valid
      expect(pay('4242 4242 4242 4242 4242')).not_to be_valid
      expect(pay('4242-4242-4242-4242')).not_to be_valid
    end
  end
end
