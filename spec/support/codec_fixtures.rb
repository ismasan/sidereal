# frozen_string_literal: true

# A domain type the JSON codec knows nothing about until an app teaches it, and
# the encoder that does the teaching — registered the way an app registers one:
# on the global +Plumb::Codec::JSON+, at load time.
#
# Shared rather than defined in one spec file because two specs need it from
# opposite sides: Sidereal's serializer encodes the whole message, Sourced's
# encodes the payload alone, and the point is that one global encoder serves
# both.
#
# The message type below joins the process-wide message registry, and every
# compile walks that registry — so a format without this encoder could not
# compile at all.
CodecMoney = Data.define(:cents, :currency)

class CodecMoneyEncoder < Plumb::Encoder[
  Plumb::Types::String[/\A-?\d+ [A-Z]{3}\z/] => Plumb::Types::Any[CodecMoney]
]
  def encode(money) = "#{money.cents} #{money.currency}"

  def decode(str)
    cents, currency = str.split
    CodecMoney.new(cents: cents.to_i, currency: currency)
  end
end

Plumb::Codec::JSON.encoder(CodecMoneyEncoder)

CodecPriced = Sidereal::Message.define('codec_spec.priced') do
  attribute :price, Plumb::Types::Any[CodecMoney]
end
