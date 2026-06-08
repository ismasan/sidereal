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

  describe 'registration lifecycle' do
    it 'allows registering after construction when no block is given' do
      container = described_class.new
      container.register(:db) { 'DB' }
      container.register(:logger) { 'LOG' }

      expect(container[:db]).to eq('DB')
      expect(container[:logger]).to eq('LOG')
    end

    it 'block form freezes the registry' do
      container = described_class.new { |c| c.register(:db) { 'DB' } }

      expect(container).to be_frozen
    end

    it 'does not freeze when constructed without a block' do
      expect(described_class.new).not_to be_frozen
    end

    it '#freeze locks the registry and resolution still works' do
      container = described_class.new
      container.register(:db) { 'DB' }

      expect(container.freeze).to be(container)
      expect(container).to be_frozen
      expect(container[:db]).to eq('DB')
    end

    it 'raises when registering after freeze' do
      container = described_class.new
      container.register(:db) { 'DB' }
      container.freeze

      expect { container.register(:logger) { 'LOG' } }.to raise_error(FrozenError)
    end
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

  describe '#inject' do
    let(:ioc) do
      described_class.new do |c|
        c.register(:db) { 'DB' }
        c.register(:logger) { 'LOG' }
        c.register(:cache) { 'CACHE' }
      end
    end

    it 'resolves declared deps from the container on .new with no args' do
      container = ioc
      klass = Class.new do
        include container.inject(:db, :logger)
        def describe = "#{db}-#{logger}"
      end

      expect(klass.new.describe).to eq('DB-LOG')
    end

    it 'lets a caller-passed kwarg override the container' do
      container = ioc
      klass = Class.new do
        include container.inject(:db, :logger)
        def describe = "#{db}-#{logger}"
      end

      expect(klass.new(db: 'OVERRIDE').describe).to eq('OVERRIDE-LOG')
    end

    it 'honors an explicitly-passed nil (does not fall back to the container)' do
      container = ioc
      klass = Class.new do
        include container.inject(:db)
        def fetch_db = db
      end

      expect(klass.new(db: nil).fetch_db).to be_nil
    end

    it 'generates private readers' do
      container = ioc
      klass = Class.new do
        include container.inject(:db, :logger)
      end

      expect(klass.private_instance_methods).to include(:db, :logger)
      expect(klass.public_instance_methods).not_to include(:db, :logger)
    end

    it 'accumulates across separate include calls' do
      container = ioc
      klass = Class.new do
        include container.inject(:db)
        include container.inject(:logger)
        def describe = "#{db}-#{logger}"
      end

      expect(klass.new.describe).to eq('DB-LOG')
    end

    it 'inherits the parent registry and lets a subclass add to it' do
      container = ioc
      base = Class.new do
        include container.inject(:db)
        def base_db = db
      end
      sub = Class.new(base) do
        include container.inject(:logger)
        def describe = "#{db}-#{logger}"
      end

      expect(sub.new.describe).to eq('DB-LOG')
      expect(base.new.base_db).to eq('DB')
    end

    it 'lets a subclass override a dep by re-including from another container' do
      container = ioc
      other = described_class.new { |c| c.register(:db) { 'OTHERDB' } }
      base = Class.new do
        include container.inject(:db)
      end
      sub = Class.new(base) do
        include other.inject(:db)
        def fetch_db = db
      end

      expect(sub.new.fetch_db).to eq('OTHERDB')
    end

    it 'maps local_attr_name => container_key' do
      container = ioc
      klass = Class.new do
        include container.inject(store: :cache)   # @store from container[:cache]
        def fetch_store = store
      end

      expect(klass.new.fetch_store).to eq('CACHE')
    end

    it 'coexists with a hand-written initialize that calls super' do
      container = ioc
      klass = Class.new do
        include container.inject(:db)
        def initialize(extra:, **rest)
          @extra = extra
          super(**rest)
        end
        def describe = "#{db}/#{@extra}"
      end

      expect(klass.new(extra: 'X').describe).to eq('DB/X')
    end
  end
end
