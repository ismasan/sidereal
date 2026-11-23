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

  describe '#inspect' do
    it 'leaves the secret out' do
      expect(signer.inspect).to eq('#<Sidereal::Signer>')
      expect(signer.inspect).not_to include('s' * 32)
      expect(described_class.new('t' * 40).inspect).to eq('#<Sidereal::Signer>')
    end
  end

  describe 'the sidereal.signer component' do
    it 'is a Signer with the key sidereal.secrets derive for it' do
      Sidereal.config.build!
      key = Sidereal::KeyGenerator.new('spec-secret-' * 6).derive('sidereal.signer')
      token = described_class.new(key).generate('hi', purpose: 'test')

      expect(Sidereal.signer).to be_a(described_class)
      expect(Sidereal.signer.verify(token, purpose: 'test')).to eq('hi')
    end

    it 'takes any signer that generates and verifies tokens' do
      signer = Struct.new(:generate, :verify).new
      Sidereal.config.config!('sidereal.signer') { signer }
      Sidereal.config.build!

      expect(Sidereal.signer).to equal(signer)
    end
  end
end
