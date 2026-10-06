# frozen_string_literal: true

DispatchBangCmd = Sidereal::Message.define('sidereal_spec.do_thing') do
  attribute :title, Sidereal::Types::String.present
end

DispatchBangNoPayload = Sidereal::Message.define('sidereal_spec.tick')

RSpec.describe Sidereal do
  it "has a version number" do
    expect(Sidereal::VERSION).not_to be nil
  end

  describe '.dispatch!' do
    let(:store) { Sidereal::Store::Memory.new }

    before { allow(Sidereal).to receive(:store).and_return(store) }

    it 'builds and appends a command from class + payload hash' do
      Sidereal.dispatch!(DispatchBangCmd, title: 'hello')

      claimed = claim_one(store)
      expect(claimed).to be_a(DispatchBangCmd)
      expect(claimed.payload.title).to eq('hello')
    end

    it 'builds and appends a no-payload command from class alone' do
      Sidereal.dispatch!(DispatchBangNoPayload)

      claimed = claim_one(store)
      expect(claimed).to be_a(DispatchBangNoPayload)
    end

    it 'appends a pre-built message instance as-is, preserving id and metadata' do
      original = DispatchBangCmd.new(payload: { title: 'pre-built' }, metadata: { channel: 'ch1' })

      Sidereal.dispatch!(original)

      claimed = claim_one(store)
      expect(claimed.id).to eq(original.id)
      expect(claimed.metadata).to eq({ channel: 'ch1' })
    end

    it 'raises on invalid payload' do
      expect { Sidereal.dispatch!(DispatchBangCmd, title: '') }.to raise_error(Plumb::ParseError)
    end

    it 'raises NoMatchingPatternError on unrecognised arguments' do
      expect { Sidereal.dispatch!('not a class', 'not a hash') }.to raise_error(NoMatchingPatternError)
    end
  end
end
