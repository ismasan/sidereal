# frozen_string_literal: true

require 'spec_helper'

RegistryCmdA = Sidereal::Message.define('registry_spec.a')
RegistryCmdB = Sidereal::Message.define('registry_spec.b')

RSpec.describe Sidereal::Registry do
  let(:registry) { described_class.new }
  let(:commander_a) { Class.new(Sidereal::Commander) }
  let(:commander_b) { Class.new(Sidereal::Commander) }

  it 'assigns and reads back commanders by command class' do
    registry[RegistryCmdA] = commander_a

    expect(registry[RegistryCmdA]).to eq(commander_a)
  end

  it 'returns nil for unknown command classes' do
    expect(registry[RegistryCmdA]).to be_nil
  end

  it 'is idempotent for the same (cmd_class, commander) pair' do
    registry[RegistryCmdA] = commander_a
    expect { registry[RegistryCmdA] = commander_a }.not_to raise_error
    expect(registry[RegistryCmdA]).to eq(commander_a)
  end

  it 'raises DuplicateHandler when a different commander claims the same cmd class' do
    registry[RegistryCmdA] = commander_a

    expect { registry[RegistryCmdA] = commander_b }
      .to raise_error(Sidereal::Registry::DuplicateHandler, /already handled/)
  end

  it 'clears the table' do
    registry[RegistryCmdA] = commander_a
    registry[RegistryCmdB] = commander_b
    registry.clear

    expect(registry[RegistryCmdA]).to be_nil
    expect(registry[RegistryCmdB]).to be_nil
  end
end
