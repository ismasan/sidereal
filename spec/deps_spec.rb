# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::Deps do
  before do
    Sidereal.config.declare('db') { :db }
    Sidereal.config.config!('sidereal.store') { double('store', append: nil) }
  end

  let(:klass) { Class.new { extend Sidereal::Deps } }

  it 'injects a component as a keyword argument with a reader, read when instantiated' do
    klass.dep :db
    Sidereal.config.build!

    expect(klass.new.db).to eq(:db)
    expect(klass.new(db: :other).db).to eq(:other)
  end

  it 'reads keys relative to Sidereal.config, and aliases with a hash' do
    klass.dep 'sidereal.store' => 'commands'
    Sidereal.config.build!

    expect(klass.new.commands).to be(Sidereal.store)
  end

  it 'takes several at once, and adds up across calls' do
    klass.dep :db
    klass.dep 'sidereal.store' => 'commands'
    Sidereal.config.build!

    instance = klass.new
    expect([instance.db, instance.commands]).to eq([:db, Sidereal.store])
  end

  it 'is the same as including the module Sidereal.config.inject returns' do
    klass.dep :db, 'sidereal.store' => 'commands'

    injector = klass.ancestors.find { |mod| mod.is_a?(Sourced::Component::Injector) }
    expect(injector.names).to eq('db' => :db, 'sidereal.store' => :commands)
  end

  it 'raises on undeclared components' do
    expect { klass.dep :missing }.to raise_error(Sourced::Component::UndeclaredComponentError, /missing/)
  end

  it 'raises when instantiated before Sidereal.config is built' do
    klass.dep :db

    expect { klass.new }.to raise_error(Sourced::Component::NotBuiltError)
  end

  it "refuses to replace the class's own methods: alias instead" do
    klass.define_method(:db) { :own }

    expect { klass.dep :db }.to raise_error(Sourced::Component::InjectionError, /already defines #db/)
  end

  describe 'on a Sidereal::Commander' do
    let(:add_todo) do
      Sidereal::Message.define('deps_spec.add_todo') do
        attribute :title, Sidereal::Types::String
      end
    end

    it "makes the component available in the commander's handlers" do
      saved = []
      Sidereal.config.declare('todos') { saved }
      commander = Class.new(Sidereal::Commander)
      commander.dep :todos
      commander.command(add_todo) { |cmd| todos << cmd.payload.title }
      Sidereal.config.build!

      commander.handle(add_todo.new(payload: { title: 'Buy milk' }), pubsub: Sidereal::PubSub::Memory.new)

      expect(saved).to eq(['Buy milk'])
    end

    it 'is inherited by subclasses' do
      parent = Class.new(Sidereal::Commander) { dep :db }
      Sidereal.config.build!

      expect(Class.new(parent).new(pubsub: nil).db).to eq(:db)
    end
  end
end
