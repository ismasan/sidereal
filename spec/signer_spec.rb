# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::Signer do
  let(:signer) { described_class.new('s' * 32) }

  describe '#generate and #verify' do
    it 'round-trips JSON data in a URL-safe token' do
      token = signer.generate({ 'page' => '/orders/:id', 'channels' => ['orders.>'] })

      expect(token).to match(/\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/)
      expect(signer.verify(token)).to eq({ 'page' => '/orders/:id', 'channels' => ['orders.>'] })
    end

    it 'rejects a token signed with another secret' do
      token = described_class.new('t' * 32).generate({ 'a' => 1 })

      expect(signer.verify(token)).to be_nil
    end

    it 'rejects a token whose data was changed' do
      _payload, signature = signer.generate({ 'a' => 1 }).split('.')
      other_payload, = signer.generate({ 'a' => 2 }).split('.')

      expect(signer.verify("#{other_payload}.#{signature}")).to be_nil
    end

    it 'rejects a token generated for another purpose' do
      token = signer.generate({ 'a' => 1 }, purpose: 'invites')

      expect(signer.verify(token, purpose: 'streams')).to be_nil
      expect(signer.verify(token)).to be_nil
      expect(signer.verify(token, purpose: 'invites')).to eq({ 'a' => 1 })
    end

    it 'rejects malformed tokens' do
      expect(signer.verify('')).to be_nil
      expect(signer.verify(nil)).to be_nil
      expect(signer.verify('abc')).to be_nil
      expect(signer.verify('a.b.c')).to be_nil
      expect(signer.verify('!!!.???')).to be_nil
    end
  end

  it 'refuses a secret shorter than 32 bytes' do
    expect { described_class.new('s' * 31) }.to raise_error(ArgumentError, /at least 32 bytes/)
  end

  describe Sidereal::Signer::Unsigned do
    let(:unsigned) { described_class.new }

    it 'round-trips JSON data in a URL-safe token' do
      token = unsigned.generate({ 'channels' => ['orders.>'] }, purpose: 'streams')

      expect(token).to match(/\A[A-Za-z0-9_-]+\z/)
      expect(unsigned.verify(token, purpose: 'streams')).to eq({ 'channels' => ['orders.>'] })
    end

    it 'rejects a token generated for another purpose' do
      token = unsigned.generate({ 'a' => 1 }, purpose: 'invites')

      expect(unsigned.verify(token, purpose: 'streams')).to be_nil
      expect(unsigned.verify(token)).to be_nil
    end

    it 'rejects tokens that do not decode' do
      expect(unsigned.verify(nil)).to be_nil
      expect(unsigned.verify('!!!')).to be_nil
      expect(unsigned.verify(Base64.urlsafe_encode64('{"a":1}'))).to be_nil
    end
  end

  describe '.default' do
    def with_env_secret(value)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with(described_class::ENV_KEY).and_return(value)
    end

    it 'signs with SIDEREAL_SECRET when it is set' do
      with_env_secret('e' * 64)

      token = described_class.default.generate({ 'a' => 1 })

      expect(described_class.new('e' * 64).verify(token)).to eq({ 'a' => 1 })
    end

    it 'encodes without signing when SIDEREAL_SECRET is unset or empty' do
      [nil, ''].each do |value|
        with_env_secret(value)

        expect(described_class.default).to be_a(described_class::Unsigned)
      end
    end

    it 'warns when it encodes without signing, and not when it signs' do
      with_env_secret(nil)
      expect(Console).to receive(:warn).with(described_class, /SIDEREAL_SECRET isn't set/).once
      described_class.default

      with_env_secret('e' * 64)
      described_class.default
    end
  end

  describe 'Sidereal.signer' do
    it 'reads the sidereal.signer component' do
      signer = described_class.new('k' * 32)
      Sidereal.config.config!('sidereal.signer') { signer }
      Sidereal.config.build!

      expect(Sidereal.signer).to equal(signer)
    end

    it 'is the default before the config is built' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with(described_class::ENV_KEY).and_return(nil)

      expect(Sidereal.signer).to be_a(described_class::Unsigned)
    end
  end
end
