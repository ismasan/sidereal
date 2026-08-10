# frozen_string_literal: true

require 'spec_helper'

# Message types used across the examples. Defined at load time: the codec
# compiles a frozen pair per type, so a type defined mid-example would be
# missing from a registry compiled earlier (spec_helper resets between
# examples to keep that honest).
CodecRich = Sidereal::Message.define('codec_spec.rich') do
  attribute :at, Sidereal::Types::Time
  attribute :on, Sidereal::Types::Date
  attribute :kind, Sidereal::Types::Symbol
  attribute :count, Sidereal::Types::Integer
end

CodecPlain = Sidereal::Message.define('codec_spec.plain') do
  attribute :n, Sidereal::Types::Integer
end

CodecEmpty = Sidereal::Message.define('codec_spec.empty')

RSpec.describe Sidereal::MessageCodec do
  subject(:codec) { described_class.new }

  let(:message) do
    CodecRich.new(payload: { at: Time.at(1_735_689_600).utc, on: Date.new(2026, 1, 2), kind: :urgent, count: 3 })
  end

  describe '#encode' do
    it 'renders every payload value in the codec format, not just the envelope' do
      encoded = codec.encode(message)

      expect(encoded[:payload][:at]).to eq('2025-01-01T00:00:00.000000Z')
      expect(encoded[:payload][:on]).to eq('2026-01-02')
      expect(encoded[:payload][:kind]).to eq('urgent')
      expect(encoded[:payload][:count]).to eq(3) # JSON-native, passes through
    end

    it 'renders the envelope too, so the whole message is one JSON-native document' do
      encoded = codec.encode(message)

      expect(encoded[:type]).to eq('codec_spec.rich')
      expect(encoded[:id]).to eq(message.id)
      expect(encoded[:created_at]).to be_a(String)
      expect { JSON.generate(encoded) }.not_to raise_error
    end

    it 'raises EncodeError naming the message when it does not satisfy its own schema' do
      # Message.new does not validate, so an invalid message can be built and
      # only fails when something tries to write it.
      invalid = CodecPlain.new(payload: { n: nil })

      expect { codec.encode(invalid) }
        .to raise_error(Sidereal::MessageCodec::EncodeError, /codec_spec\.plain \(#{invalid.id}\)/)
    end
  end

  describe '#decode' do
    it 'restores the types the schema declares' do
      decoded = codec.decode(codec.encode(message))

      expect(decoded).to be_a(CodecRich)
      expect(decoded.payload.at).to eq(message.payload.at)
      expect(decoded.payload.on).to eq(Date.new(2026, 1, 2))
      expect(decoded.payload.kind).to eq(:urgent)
      expect(decoded.created_at).to be_a(Time)
    end

    it 'survives a real JSON round trip, which is what the transports do' do
      json = JSON.generate(codec.encode(message))
      decoded = codec.decode(JSON.parse(json, symbolize_names: true))

      expect(decoded.payload.at).to eq(message.payload.at)
      expect(decoded.payload.kind).to eq(:urgent)
    end

    it 'handles a message defined without a payload' do
      msg = CodecEmpty.new
      expect(codec.decode(codec.encode(msg)).type).to eq('codec_spec.empty')
    end

    it 'raises UnknownMessageError for a type this process does not know' do
      expect { codec.decode({ type: 'codec_spec.from_the_future', id: 'abc' }) }
        .to raise_error(Sourced::Message::UnknownMessageError, /codec_spec\.from_the_future/)
    end

    it 'raises DecodeError naming the message when stored values no longer fit the schema' do
      expect { codec.decode({ type: 'codec_spec.plain', id: 'abc', payload: { n: 'not a number' } }) }
        .to raise_error(described_class::DecodeError, /codec_spec\.plain \(abc\)/)
    end
  end

  describe '#compile!' do
    it 'is the boot check: raises for a type this format cannot represent' do
      # A private registry, so an unrepresentable type never reaches the shared
      # one — where it would fail every other example's compile.
      unrepresentable = Class.new(Plumb::Types::Data) do
        attribute :anything, Plumb::Types::Any
        def self.type = 'codec_spec.unrepresentable'
      end
      registry = double('registry')
      allow(registry).to receive(:all) { |&block| block.call(unrepresentable) }

      expect { described_class.new(registry: registry).compile! }
        .to raise_error(Plumb::TypeError, /anything/)
    end

    it 'reports whether it has been compiled' do
      expect { codec.compile! }.to change(codec, :compiled?).from(false).to(true)
    end

    it 'is idempotent, so every transport sharing it can call it on start' do
      codec.compile!
      first = codec.encode(message)

      expect { codec.compile! }.not_to change(codec, :compiled?)
      expect(codec.encode(message)).to eq(first)
    end

    it 'compiles types registered before it ran, and only those' do
      codec.compile!
      Sidereal::Message.define('codec_spec.after_compile')

      expect(codec.registered?('codec_spec.after_compile')).to be false
    end

    it 'registers a pair per known message type' do
      codec.compile!
      expect(codec.registered?('codec_spec.rich')).to be true
      expect(codec.registered?('codec_spec.nope')).to be false
    end
  end

  describe '.default' do
    it 'is the one instance the transports share, so they compile once' do
      expect(described_class.default).to be(described_class.default)
    end

    it 'is dropped by a reload, so the next one sees the current registry' do
      first = described_class.default
      Sidereal.reload!
      expect(described_class.default).not_to be(first)
    end
  end

  describe 'recompiling after a reload' do
    def pair_for(klass) = described_class.pairs.dig(klass, Plumb::Codec::JSON)

    it 'reuses a class\'s compiled pair, so a reload re-collects rather than rebuilds' do
      codec.compile!
      first = pair_for(CodecRich)

      Sidereal.reload!
      Sidereal.message_codec.compile!

      expect(pair_for(CodecRich)).to be(first)
    end

    it 'builds a pair only for a class it has not compiled yet' do
      codec.compile!
      before = described_class.pairs.keys

      late = Sidereal::Message.define('codec_spec.late') { attribute :n, Sidereal::Types::Integer }
      described_class.new.compile!

      expect(described_class.pairs.keys - before).to eq([late])
    end

    it 'still round-trips through a reused pair' do
      codec.compile!
      Sidereal.reload!

      decoded = Sidereal.message_codec.decode(Sidereal.message_codec.encode(message))
      expect(decoded.payload.at).to eq(message.payload.at)
      expect(decoded.payload.kind).to eq(:urgent)
    end

    it 'rebuilds from scratch after clear_pairs!, for a schema that changed in place' do
      codec.compile!
      first = pair_for(CodecRich)

      described_class.clear_pairs!
      described_class.new.compile!

      expect(pair_for(CodecRich)).not_to be(first)
    end
  end

  describe 'compiling lazily' do
    it 'works without a Host, so a store or script can be driven directly' do
      expect(codec).not_to be_compiled
      expect(codec.encode(message)[:type]).to eq('codec_spec.rich')
      expect(codec).to be_compiled
    end
  end
end
