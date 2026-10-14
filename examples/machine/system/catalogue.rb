# frozen_string_literal: true

# What a holiday can be made of: destinations with their flights and hotels,
# and the rooms, board and extras any hotel offers. Fixed data, so a booking
# only needs to record codes.
module Catalogue
  Flight = Data.define(:code, :airline, :departs, :arrives, :price)
  Hotel = Data.define(:code, :name, :stars, :nightly)
  Option = Data.define(:code, :name, :price, :note)

  Destination = Data.define(:code, :name, :country, :flights, :hotels)

  DESTINATIONS = [
    Destination.new(
      code: 'lisbon', name: 'Lisbon', country: 'Portugal',
      flights: [
        Flight.new(code: 'TP1351', airline: 'Atlantic Air', departs: '07:10', arrives: '09:40', price: 129),
        Flight.new(code: 'SR2208', airline: 'Sidereal Wings', departs: '13:25', arrives: '15:55', price: 98),
        Flight.new(code: 'NL4410', airline: 'Night Line', departs: '22:05', arrives: '00:35', price: 74)
      ],
      hotels: [
        Hotel.new(code: 'alfama-azul', name: 'Casa Azul, Alfama', stars: 3, nightly: 84),
        Hotel.new(code: 'tejo-palace', name: 'Tejo Palace', stars: 5, nightly: 230)
      ]
    ),
    Destination.new(
      code: 'kyoto', name: 'Kyoto', country: 'Japan',
      flights: [
        Flight.new(code: 'JL0044', airline: 'Crane Airways', departs: '11:30', arrives: '07:55', price: 812),
        Flight.new(code: 'SR9001', airline: 'Sidereal Wings', departs: '19:45', arrives: '15:20', price: 694)
      ],
      hotels: [
        Hotel.new(code: 'gion-ryokan', name: 'Gion Ryokan', stars: 4, nightly: 190),
        Hotel.new(code: 'kamo-river', name: 'Kamo River Inn', stars: 3, nightly: 112)
      ]
    ),
    Destination.new(
      code: 'reykjavik', name: 'Reykjavík', country: 'Iceland',
      flights: [
        Flight.new(code: 'FI0451', airline: 'Aurora Air', departs: '08:50', arrives: '11:05', price: 241),
        Flight.new(code: 'SR3113', airline: 'Sidereal Wings', departs: '20:15', arrives: '22:30', price: 189)
      ],
      hotels: [
        Hotel.new(code: 'harbour-lights', name: 'Harbour Lights', stars: 4, nightly: 175),
        Hotel.new(code: 'lava-lodge', name: 'Lava Field Lodge', stars: 3, nightly: 128)
      ]
    )
  ].to_h { |d| [d.code, d] }.freeze

  ROOMS = [
    Option.new(code: 'standard', name: 'Standard double', price: 0, note: 'Included'),
    Option.new(code: 'view', name: 'Room with a view', price: 35, note: '+€35 a night'),
    Option.new(code: 'suite', name: 'Suite', price: 120, note: '+€120 a night')
  ].to_h { |o| [o.code, o] }.freeze

  BOARDS = [
    Option.new(code: 'room-only', name: 'Room only', price: 0, note: 'Included'),
    Option.new(code: 'breakfast', name: 'Bed & breakfast', price: 18, note: '+€18 per person a night'),
    Option.new(code: 'half-board', name: 'Half board', price: 45, note: '+€45 per person a night')
  ].to_h { |o| [o.code, o] }.freeze

  EXTRAS = [
    Option.new(code: 'insurance', name: 'Travel insurance', price: 39, note: '€39 per person'),
    Option.new(code: 'transfer', name: 'Airport transfers', price: 60, note: '€60 return'),
    Option.new(code: 'luggage', name: 'Checked luggage', price: 45, note: '€45 per person'),
    Option.new(code: 'stargazing', name: 'Night-sky tour', price: 55, note: '€55 per person')
  ].to_h { |o| [o.code, o] }.freeze

  PER_PERSON_EXTRAS = %w[insurance luggage stargazing].freeze

  def self.destination(code) = DESTINATIONS.fetch(code)
  def self.flight(code) = DESTINATIONS.values.flat_map(&:flights).find { |f| f.code == code }
  def self.hotel(code) = DESTINATIONS.values.flat_map(&:hotels).find { |h| h.code == code }

  def self.flight_codes = DESTINATIONS.values.flat_map { |d| d.flights.map(&:code) }
  def self.hotel_codes = DESTINATIONS.values.flat_map { |d| d.hotels.map(&:code) }
end
