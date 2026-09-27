# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::Deps do
  before do
    Sidereal.dependencies.register!('store') { :store }
    Sidereal.dependencies.register!('sourced.store') { :sourced_store }
  end

  let(:klass) { Class.new { extend Sidereal::Deps } }

  it 'injects a dependency as a keyword argument with a reader' do
    klass.dep :store

    expect(klass.new.store).to eq(:store)
    expect(klass.new(store: :other).store).to eq(:other)
  end

  it 'aliases with a hash' do
    klass.dep 'sourced.store' => 'st'

    expect(klass.new.st).to eq(:sourced_store)
  end

  it 'takes several at once, and adds up across calls' do
    klass.dep :store
    klass.dep 'sourced.store' => 'st'

    instance = klass.new
    expect([instance.store, instance.st]).to eq(%i[store sourced_store])
  end

  it 'is the same as including the module Sidereal.dependencies.args returns' do
    klass.dep :store, 'sourced.store' => 'st'

    injection = klass.ancestors.find { |mod| mod.is_a?(Sidereal::Dependencies::Injection) }
    expect(injection.names).to eq(store: 'store', st: 'sourced.store')
  end

  it 'records what the class injects, so build! checks it' do
    klass.dep :missing

    expect { Sidereal.dependencies.build! }
      .to raise_error(Sidereal::Dependencies::UnknownDependencyError, /injects 'missing'/)
  end

  describe 'on a Sidereal::Commander' do
    let(:add_todo) do
      Sidereal::Message.define('deps_spec.add_todo') do
        attribute :title, Sidereal::Types::String
      end
    end

    it "makes the dependency available in the commander's handlers" do
      saved = []
      Sidereal.dependencies.register!('todos') { saved }
      commander = Class.new(Sidereal::Commander)
      commander.dep :todos
      commander.command(add_todo) { |cmd| todos << cmd.payload.title }

      commander.handle(add_todo.new(payload: { title: 'Buy milk' }), pubsub: Sidereal::PubSub::Memory.new)

      expect(saved).to eq(['Buy milk'])
    end

    it 'is inherited by subclasses' do
      parent = Class.new(Sidereal::Commander) { dep :store }

      expect(Class.new(parent).new(pubsub: nil).store).to eq(:store)
    end
  end
end
