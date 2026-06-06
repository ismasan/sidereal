# frozen_string_literal: true

require 'spec_helper'

# The generic message machinery (define/from/registry/payload/correlate/#at/…)
# is exercised in the sourced-message gem's own suite. Here we only cover the
# Sidereal-specific wiring: that Sidereal::Message is a Sourced::Message, and
# that both libraries resolve through one shared root registry.
RSpec.describe Sidereal::Message do
  let(:msg_class) do
    Sidereal::Message.define('spec.sidereal_thing') do
      attribute :name, Sidereal::Types::String
    end
  end

  it 'is a subclass of Sourced::Message' do
    expect(Sidereal::Message.ancestors).to include(Sourced::Message)
  end

  it 'inherits the scoped error constants from the gem' do
    expect(Sidereal::Message::UnknownMessageError).to eq(Sourced::Message::UnknownMessageError)
    expect(Sidereal::Message::PastMessageDateError).to eq(Sourced::Message::PastMessageDateError)
  end

  describe 'shared root registry' do
    it 'resolves a Sidereal-defined type from the Sourced::Message root' do
      klass = msg_class
      msg = Sourced::Message.from(type: 'spec.sidereal_thing', payload: { name: 'Joe' })
      expect(msg).to be_a(klass)
      expect(msg.payload.name).to eq('Joe')
    end

    it 'resolves a Sourced::Message-defined type from the root' do
      klass = Sourced::Message.define('spec.sourced_thing')
      msg = Sourced::Message.from(type: 'spec.sourced_thing')
      expect(msg).to be_a(klass)
    end
  end
end
