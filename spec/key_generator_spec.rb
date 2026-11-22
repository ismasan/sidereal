# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::KeyGenerator do
  subject(:keys) { described_class.new('m' * 64) }

  describe '#derive' do
    it 'derives a 64-byte binary key for each purpose' do
      key = keys.derive('session')

      expect(key.bytesize).to eq(64)
      expect(key.encoding).to eq(Encoding::BINARY)
      expect(keys.derive('sidereal.signer')).not_to eq(key)
    end

    it 'derives the same key from the same secret and purpose' do
      expect(described_class.new('m' * 64).derive('session')).to eq(keys.derive('session'))
      expect(described_class.new('n' * 64).derive('session')).not_to eq(keys.derive('session'))
    end

    it 'derives keys of any length' do
      expect(keys.derive('session', length: 32).bytesize).to eq(32)
    end

    it 'derives keys a Sidereal::Signer and Rack sessions accept' do
      expect { Sidereal::Signer.new(keys.derive('sidereal.signer')) }.not_to raise_error
      expect { Rack::Session::Cookie.new(->(_) {}, secret: keys.derive('session')) }.not_to raise_error
    end
  end

  it 'refuses a secret shorter than 64 bytes' do
    expect { described_class.new('m' * 63) }.to raise_error(ArgumentError, 'master secret must be at least 64 bytes')
  end

  it 'leaves the secret out of #inspect' do
    expect(keys.inspect).to eq('#<Sidereal::KeyGenerator>')
  end

  describe '.generate_secret' do
    it 'makes a secret long enough to derive from, different each time' do
      secret = described_class.generate_secret

      expect(secret).to match(/\A\h{64}\z/)
      expect { described_class.new(secret) }.not_to raise_error
      expect(described_class.generate_secret).not_to eq(secret)
    end
  end
end
