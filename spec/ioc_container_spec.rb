# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'sidereal/ioc_container'

RSpec.describe Sidereal::IOCContainer do
  it 'is thread-safe' do
    counts = []
    container = described_class.new do |ioc|
      ioc.register(:foo) do |c|
        sleep 0.001
        counts << 1
      end
    end

    1.upto(10).map do |i|
      Thread.new do
        container[:foo]
      end
    end.map &:join

    expect(counts.size).to eq 1
    expect(container[:foo]).to eq [1]
  end

  it 'is fiber-safe: runs a block once across concurrent fibers that yield' do
    count = 0
    container = described_class.new do |ioc|
      ioc.register(:foo) do |c|
        count += 1
        sleep 0.001 # yields the fiber under the Async reactor
        'bar'
      end
    end

    results = []
    Sync do |task|
      5.times.map { task.async { results << container[:foo] } }.each(&:wait)
    end

    expect(count).to eq(1)
    expect(results).to eq(['bar'] * 5)
  end

  describe 'memoize: current_fiber' do
    it 'memoizes only in the context of the current fiber' do
      count = 0
      container = described_class.new do |ioc|
        ioc.register(:foo, memoize: :current_fiber) do |c|
          count += 1
          'bar'
        end
      end

      Sync do |task|
        task.async { 2.times { container[:foo] } }.wait
        task.async { 2.times { container[:foo] } }.wait
      end

      expect(count).to eq(2)
    end

    it 'isolates sibling threads (each root fiber gets its own)' do
      count = 0
      container = described_class.new do |ioc|
        ioc.register(:foo, memoize: :current_fiber) do |c|
          count += 1
          'bar'
        end
      end

      2.times.map do
        Thread.new { 2.times { container[:foo] } }
      end.each(&:join)

      expect(count).to eq(2)
    end
  end

  it 'defines keys that depend on other keys' do
    container = described_class.new do |ioc|
      ioc.register(:title) do |c|
        'Mr'
      end
      ioc.register(:name) do |c|
        "#{c[:title]} Ismael"
      end
    end

    expect(container[:name]).to eq('Mr Ismael')
  end

  describe 'memoize: false' do
    it 'does not memoize' do
      count = 0
      container = described_class.new do |ioc|
        ioc.register(:foo, memoize: false) do |c|
          count += 1
          'bar'
        end
      end

      3.times { container[:foo] }
      expect(count).to eq(3)
    end
  end

  describe 'extend .inject' do
    let!(:ioc) do
      described_class.new do |ioc|
        ioc.register(:a) do |c|
          'A'
        end
        ioc.register(:b) do |c|
          'B'
        end
      end
    end

    it 'defines .build factory' do
      klass = Class.new do
        attr_reader :a, :b, :c
        def initialize(a:, b:, c: 'C')
          @a, @b, @c = a, b, c
        end
      end

      klass.extend ioc.inject(:a, :b)

      instance = klass.build
      expect(instance.a).to eq('A')
      expect(instance.b).to eq('B')
      expect(instance.c).to eq('C')

      instance = klass.build(b: 'BB', c: 'CC')
      expect(instance.a).to eq('A')
      expect(instance.b).to eq('BB')
      expect(instance.c).to eq('CC')
    end

    it 'maps hash to IOC arg => constructor arg' do
      klass = Class.new do
        attr_reader :aa1, :bb1
        def initialize(aa1:, bb1:)
          @aa1, @bb1 = aa1, bb1
        end
      end

      klass.extend ioc.inject(a: :aa1, b: :bb1)

      instance = klass.build
      expect(instance.aa1).to eq('A')
      expect(instance.bb1).to eq('B')
    end
  end

  describe 'include #methods' do
    let!(:ioc) do
      described_class.new do |ioc|
        ioc.register('methods.a') do |c|
          'A'
        end
        ioc.register(:b) do |c|
          'B'
        end
      end
    end

    it 'includes methods to access system registers' do
      klass = Class.new
      klass.include ioc.methods(:b)
      klass.include ioc.methods('methods.a' => :method_a)

      instance = klass.new
      expect(instance.b).to eq('B')
      expect(instance.method_a).to eq('A')
    end
  end
end
