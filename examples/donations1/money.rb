# frozen_string_literal: true

require 'plumb'

# A domain type neither codec knows anything about until this file teaches them.
#
# Money is the value object a donations app actually wants: an amount is never
# just a number, it is a number *and* a currency, and keeping the two together
# is what stops a '€' getting hardcoded into every template.
Money = Data.define(:cents, :currency) do
  SYMBOLS = { 'EUR' => '€', 'GBP' => '£', 'USD' => '$' }.freeze

  def self.euros(units) = new(cents: units * 100, currency: 'EUR')

  def symbol = SYMBOLS.fetch(currency, "#{currency} ")

  # "30" for a whole amount, "12.50" otherwise — kiosk presets are round numbers
  # and a trailing ".00" is noise on a button. Split from {#symbol} so the amount
  # buttons can typeset the two parts differently.
  def units
    value = cents / 100.0
    format(value % 1 == 0 ? '%d' : '%.2f', value)
  end

  def to_s = "#{symbol}#{units}"
end

# The same Ruby type reaches the wire in two different shapes, because the two
# formats can carry different things — which is exactly why Sidereal's JSON and
# Forms codecs keep separate compiled pairs for one message class.

# A form field is a String and nothing else, so the two parts are packed into
# one: "3000 EUR". This is what the hidden `command[payload][amount]` input
# carries when a preset button is rendered, and what comes back on submit.
#
# The input side needs the `Types::` form because it is a *refinement* — only
# strings matching that pattern. A plain class would do where no refinement is
# involved, as on the output side and in MoneyJSONEncoder below.
class MoneyFormsEncoder < Plumb::Encoder[
  Plumb::Types::String[/\A\d+ [A-Z]{3}\z/] => Money
]
  def encode(money) = "#{money.cents} #{money.currency}"

  def decode(str)
    cents, currency = str.split
    Money.new(cents: cents.to_i, currency:)
  end
end

# JSON has objects, so the parts stay addressable — a stored message can be
# queried or read by a human without anyone re-parsing a packed string.
class MoneyJSONEncoder < Plumb::Encoder[
  Plumb::Types::Hash[cents: Integer, currency: String] => Money
]
  def encode(money) = { cents: money.cents, currency: money.currency }

  def decode(hash) = Money.new(cents: hash[:cents], currency: hash[:currency])
end

# Registered at load time, on the global codec classes, before any message type
# is defined — every compile walks the whole message registry, so a format
# missing an encoder for Money could not compile at all. The web boundary
# compiles at `handle`; the transports compile when the store and pubsub start.
Plumb::Codec::Forms.encoder(MoneyFormsEncoder)
Plumb::Codec::JSON.encoder(MoneyJSONEncoder)
