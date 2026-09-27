# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::Dependencies do
  subject(:deps) { described_class.new }

  describe '#register! and #[]' do
    it 'memoizes a singleton' do
      deps.register!('db') { Object.new }

      expect(deps['db']).to be(deps['db'])
    end

    it 'builds a transient on every call' do
      deps.register('conn') { Object.new }

      expect(deps['conn']).not_to be(deps['conn'])
    end

    it 'resolves dependencies first and passes their values in order, whatever the registration order' do
      deps.register!('store', %w[db logger]) { |db, logger| [:store, db, logger] }
      deps.register!('logger') { :logger }
      deps.register!('db') { :db }

      expect(deps['store']).to eq([:store, :db, :logger])
    end

    it 'gives a transient a fresh value of a transient dependency, and the same value of a singleton' do
      deps.register!('db') { Object.new }
      deps.register('conn') { Object.new }
      deps.register('repo', %w[db conn]) { |db, conn| [db, conn] }

      first, second = deps['repo'], deps['repo']
      expect(first[0]).to be(second[0])
      expect(first[1]).not_to be(second[1])
    end

    it 'accepts symbol keys' do
      deps.register!(:db) { :db }
      deps.register!('store', [:db]) { |db| [:store, db] }

      expect(deps[:store]).to eq([:store, :db])
      expect(deps).to be_key(:db)
    end

    it "keeps the caller's self in the block" do
      deps.register!('db') { caller_value }

      expect(deps['db']).to eq(:from_the_caller)
    end

    def caller_value = :from_the_caller

    it 'builds a singleton once when fibers ask for it concurrently' do
      builds = 0
      deps.register!('db') do
        builds += 1
        sleep 0.01 # yields to the other fiber under the scheduler
        Object.new
      end

      values = Sync do |task|
        2.times.map { task.async { deps['db'] } }.map(&:wait)
      end

      expect(builds).to eq(1)
      expect(values.uniq.size).to eq(1)
    end

    it 'raises for an unknown key' do
      expect { deps['nope'] }.to raise_error(described_class::UnknownDependencyError, "'nope' is not registered")
    end

    it 'raises for an unknown dependency, naming the dependent' do
      deps.register!('store', ['db']) { |db| db }

      expect { deps['store'] }
        .to raise_error(described_class::UnknownDependencyError, "'store' depends on 'db', which is not registered")
    end

    it 'raises for a cycle instead of recursing' do
      deps.register!('a', ['b']) { :a }
      deps.register!('b', ['a']) { :b }

      expect { deps['a'] }.to raise_error(described_class::CircularDependencyError, /'a'/)
    end

    it 'raises for a dependency on itself' do
      deps.register('a', ['a']) { :a }

      expect { deps['a'] }.to raise_error(described_class::CircularDependencyError)
    end

    it 'refuses a duplicate key' do
      deps.register!('db') { :one }

      expect { deps.register('db') { :two } }
        .to raise_error(described_class::DuplicateDependencyError, "'db' is already registered. Pass override: true to replace it")
    end

    it 'requires a block' do
      expect { deps.register!('db') }.to raise_error(ArgumentError, /block that builds it/)
    end

    it 'refuses a teardown on a transient dependency' do
      registration = deps.register('conn') { :conn }

      expect { registration.teardown { |_c| } }.to raise_error(ArgumentError, /transient/)
    end

    describe 'override: true' do
      it 'replaces a registration' do
        deps.register!('db') { :one }
        deps.register('db', override: true) { Object.new }

        expect(deps['db']).not_to be(deps['db'])
      end

      it 'adds a key that is not registered yet' do
        deps.register!('db', override: true) { :db }

        expect(deps['db']).to eq(:db)
      end

      it 'is picked up by dependents not yet built' do
        deps.register!('db') { :one }
        deps.register!('store', ['db']) { |db| [:store, db] }
        deps.register!('db', override: true) { :two }

        expect(deps['store']).to eq([:store, :two])
      end

      it 'is refused once the key has been resolved' do
        deps.register!('db') { :one }
        deps['db']

        expect { deps.register!('db', override: true) { :two } }
          .to raise_error(described_class::ResolvedDependencyError, /'db' has already been resolved/)
      end

      it 'is refused once a singleton built from the key has been resolved, even through a transient' do
        deps.register('conn') { :one }
        deps.register('repo', ['conn']) { |conn| conn }
        deps.register!('store', ['repo']) { |repo| repo }
        deps['store']

        expect { deps.register('conn', override: true) { :two } }
          .to raise_error(described_class::ResolvedDependencyError, /'store' has already been resolved/)
      end
    end
  end

  describe '#build!' do
    it 'builds every singleton, dependencies first, and no transient' do
      built = []
      deps.register!('store', ['db']) { built << :store }
      deps.register!('db') { built << :db }
      deps.register('conn') { built << :conn }

      deps.build!

      expect(built).to eq(%i[db store])
      expect(deps).to be_built
    end

    it 'locks the container' do
      deps.build!

      expect { deps.register!('db') { :db } }.to raise_error(described_class::LockedError)
      expect { deps.register!('db', override: true) { :db } }.to raise_error(described_class::LockedError)
    end

    it 'is idempotent' do
      builds = 0
      deps.register!('db') { builds += 1 }

      deps.build!
      deps.build!

      expect(builds).to eq(1)
    end

    it 'raises for a missing dependency anywhere in the graph, without locking' do
      deps.register('store', ['db']) { |db| db }

      expect { deps.build! }.to raise_error(described_class::UnknownDependencyError, /'db'/)
      expect(deps).not_to be_built
    end

    it 'raises for a cycle anywhere in the graph' do
      deps.register('a', ['b']) { :a }
      deps.register('b', ['c']) { :b }
      deps.register('c', ['a']) { :c }

      expect { deps.build! }.to raise_error(described_class::CircularDependencyError, /'a'.*'b'.*'c'|'c'.*'b'.*'a'/)
    end

    it 'raises for a key injected with #args that is not registered' do
      klass = Class.new
      klass.include deps.args('db')

      expect { deps.build! }.to raise_error(described_class::UnknownDependencyError, /injects 'db'/)
    end

    it 'names the injecting class' do
      stub_const('GamesProjector', Class.new)
      GamesProjector.include deps.args('db')

      expect { deps.build! }
        .to raise_error(described_class::UnknownDependencyError, "GamesProjector injects 'db', which is not registered")
    end
  end

  describe 'across a fork' do
    # Runs the block in a forked child and returns what it wrote.
    def in_child
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        writer.write(yield.to_s)
        writer.close
        exit!(0)
      end
      writer.close
      Process.wait(pid)
      reader.read
    end

    it 'refuses to build in the process that forbade builds' do
      deps.register!('db') { :db }
      deps.forbid_builds!

      expect { deps['db'] }.to raise_error(described_class::ForkError, /Cannot build 'db' in the process that forks/)
      expect { deps.build! }.to raise_error(described_class::ForkError)
    end

    it 'still accepts registrations in the process that forbade builds' do
      deps.forbid_builds!

      expect { deps.register!('db') { :db } }.not_to raise_error
    end

    it 'builds in a child of the process that forbade builds' do
      deps.register!('db') { :db }
      deps.forbid_builds!

      expect(in_child { deps.build!['db'] }).to eq('db')
    end

    it 'refuses values a parent built and a child inherited' do
      deps.register!('db') { Object.new }
      deps['db']

      message = in_child do
        deps['db']
        'used'
      rescue described_class::ForkError => e
        e.message
      end

      expect(message).to match(/'db' were built in process #{Process.pid} and inherited/)
    end
  end

  describe '#teardown' do
    it 'runs the teardowns of built singletons, dependents first' do
      torn = []
      deps.register!('db') { :db }.teardown { |db| torn << db }
      deps.register!('store', ['db']) { :store }.teardown { |store| torn << store }
      deps.register!('cache', ['store']) { :cache }.teardown { |cache| torn << cache }
      deps.build!

      deps.teardown

      expect(torn).to eq(%i[cache store db])
    end

    it 'tears down only what was built' do
      torn = []
      deps.register!('db') { :db }.teardown { |db| torn << db }
      deps.register!('unused') { :unused }.teardown { |v| torn << v }
      deps['db']

      deps.teardown

      expect(torn).to eq([:db])
    end

    it 'skips singletons without a teardown' do
      deps.register!('db') { :db }
      deps.build!

      expect { deps.teardown }.not_to raise_error
    end

    it 'keeps tearing down the rest when a teardown raises' do
      torn = []
      deps.register!('db') { :db }.teardown { |db| torn << db }
      deps.register!('store', ['db']) { :store }.teardown { raise 'boom' }
      deps.build!

      deps.teardown

      expect(torn).to eq([:db])
    end

    it 'is idempotent, and lets a later build! build afresh' do
      teardowns = 0
      deps.register!('db') { Object.new }.teardown { teardowns += 1 }
      deps.build!
      first = deps['db']

      deps.teardown
      deps.teardown
      deps.build!

      expect(teardowns).to eq(1)
      expect(deps['db']).not_to be(first)
    end
  end

  describe '#inspect' do
    it 'names the state when empty' do
      expect(deps.inspect).to eq('#<Sidereal::Dependencies (open)>')
    end

    it 'lists each key with the keys it depends on, in registration order' do
      deps.register!('dispatcher', %w[db logger]) { :dispatcher }
      deps.register!('logger', ['printer']) { :logger }
      deps.register('printer') { :printer }
      deps.register!('db') { :db }

      expect(deps.inspect).to eq('#<Sidereal::Dependencies (open) dispatcher[db, logger] logger[printer] printer db>')
    end

    it 'says when the container is built' do
      deps.register!('db') { :db }
      deps.build!

      expect(deps.inspect).to eq('#<Sidereal::Dependencies (built) db>')
    end

    it 'pretty-prints one dependency per line when they do not fit on one' do
      deps.register!('a.fairly.long.database.key') { :db }
      deps.register('another.fairly.long.connection.key', ['a.fairly.long.database.key']) { :conn }

      expect(PP.pp(deps, +'', 60)).to eq(<<~TEXT)
        #<Sidereal::Dependencies (open)
          a.fairly.long.database.key
          another.fairly.long.connection.key[a.fairly.long.database.key]>
      TEXT
    end

    it "shows a registration with its block's location" do
      registration = deps.register!('db', ['conn']) { :db }

      expect(registration.inspect)
        .to eq(%(#<Sidereal::Dependencies::Registration register! db[conn] at #{__FILE__}:#{__LINE__ - 3}>))
    end
  end

  describe '#args' do
    before do
      deps.register!('db') { :db }
      deps.register!('sourced.store') { :store }
      deps.register!('logger') { :logger }
    end

    it 'injects a keyword argument named after the last key segment, with a reader' do
      klass = Class.new
      klass.include deps.args('sourced.store')

      instance = klass.new
      expect(instance.store).to eq(:store)
    end

    it 'takes an explicit value over the container' do
      klass = Class.new
      klass.include deps.args('db')

      expect(klass.new(db: :other).db).to eq(:other)
    end

    it 'aliases keys given as a hash' do
      klass = Class.new
      klass.include deps.args('db', 'sourced.store' => 'st')

      instance = klass.new
      expect(instance.st).to eq(:store)
      expect(instance.db).to eq(:db)
    end

    it 'adds up across includes' do
      klass = Class.new
      klass.include deps.args('sourced.store')
      klass.include deps.args('logger')

      instance = klass.new(logger: :mine)
      expect([instance.store, instance.logger]).to eq(%i[store mine])
    end

    it "runs the class's own #initialize, which need not call super, with the remaining arguments" do
      klass = Class.new do
        attr_reader :name, :opts, :blk

        def initialize(name, flag: false, &blk)
          @name = name
          @opts = { flag: }
          @blk = blk
        end
      end
      klass.include deps.args('db')

      instance = klass.new('x', flag: true, db: :other) { :block }
      expect([instance.name, instance.opts, instance.blk.call, instance.db]).to eq(['x', { flag: true }, :block, :other])
    end

    it "passes a positional hash to an inherited #initialize untouched (Sourced reactors' shape)" do
      base = Class.new do
        attr_reader :partition_values

        def initialize(partition_values = {})
          @partition_values = partition_values
        end
      end
      klass = Class.new(base)
      klass.include deps.args('db')

      instance = klass.new({ game_id: 'g1' })
      expect([instance.partition_values, instance.db]).to eq([{ game_id: 'g1' }, :db])
    end

    it 'is inherited by subclasses' do
      parent = Class.new
      parent.include deps.args('db')

      expect(Class.new(parent).new.db).to eq(:db)
    end

    it 'resolves defaults on each instantiation, so it can be included before registering' do
      late = described_class.new
      klass = Class.new
      klass.include late.args('later')
      late.register('later') { Object.new }

      expect(klass.new.later).not_to be(klass.new.later)
    end

    it 'exposes real keyword parameters' do
      injection = deps.args('db', 'sourced.store' => 'st')

      expect(injection.instance_method(:initialize).parameters).to include([:key, :db], [:key, :st])
      expect(injection.names).to eq(db: 'db', st: 'sourced.store')
    end

    it 'does not resolve a default for a value it is given' do
      builds = 0
      deps.register('conn') { builds += 1 }
      klass = Class.new
      klass.include deps.args('conn')

      klass.new(conn: :given)

      expect(builds).to eq(0)
    end

    it 'refuses a name the class already has, since the reader would replace it' do
      klass = Class.new do
        def db = :own
      end

      expect { klass.include deps.args('db') }.to raise_error(ArgumentError, /already has #db.*Alias it: 'db' => 'another_name'/)
    end

    it 'refuses a private method too' do
      klass = Class.new do
        private def db = :own
      end

      expect { klass.include deps.args('db') }.to raise_error(ArgumentError, /already has #db/)
    end

    it 'lets a subclass inject again a name its parent injected' do
      parent = Class.new
      parent.include deps.args('db')
      child = Class.new(parent)

      expect { child.include deps.args('sourced.store' => 'db') }.not_to raise_error
      expect(child.new.db).to eq(:store)
    end

    it 'refuses two keys that inject under the same name' do
      expect { deps.args('sourced.store', 'fs.store') }.to raise_error(ArgumentError, /both inject as 'store'/)
    end

    it 'refuses a name that is not a valid keyword' do
      expect { deps.args('my-db') }.to raise_error(ArgumentError, /not a valid keyword argument/)
    end
  end
end
