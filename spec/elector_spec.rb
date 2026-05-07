# frozen_string_literal: true

require 'spec_helper'
require 'sidereal/elector/file_system'
require 'tmpdir'

# Test elector that exposes promote!/demote! to drive transitions
# from specs without spawning a real election fiber.
class TestElector
  include Sidereal::Elector::Callbacks

  def initialize
    @leader = false
  end

  def leader? = @leader
  def start(_task) = self
  def promote! = super
  def demote! = super
end

RSpec.describe Sidereal::Elector do
  describe Sidereal::Elector::AlwaysLeader do
    subject(:elector) { described_class.new }

    it 'is leader from construction' do
      expect(elector.leader?).to be true
    end

    it 'fires on_promote immediately at registration' do
      called = false
      elector.on_promote { called = true }
      expect(called).to be true
    end

    it 'does not fire on_demote at registration when leader' do
      called = false
      elector.on_demote { called = true }
      expect(called).to be false
    end

    it 'returns self for chaining from on_promote/on_demote' do
      expect(elector.on_promote {}).to eq(elector)
      expect(elector.on_demote {}).to eq(elector)
    end

    it '#start is a no-op that returns self' do
      expect(elector.start(:fake_task)).to eq(elector)
    end
  end

  describe 'Callbacks mixin (transition semantics)' do
    subject(:elector) { TestElector.new }

    it 'fires on_demote at registration when not yet leader' do
      called = false
      elector.on_demote { called = true }
      expect(called).to be true
    end

    it 'does not fire on_promote at registration when not yet leader' do
      called = false
      elector.on_promote { called = true }
      expect(called).to be false
    end

    it 'fires on_promote on the follower→leader transition' do
      fired = []
      elector.on_promote { fired << :promoted }
      elector.promote!
      expect(fired).to eq([:promoted])
    end

    it 'fires on_demote on the leader→follower transition' do
      elector.promote!
      fired = []
      elector.on_demote { fired << :demoted }
      elector.promote!     # already leader: no-op
      elector.demote!
      expect(fired).to eq([:demoted])
    end

    it 'is idempotent: repeated promote!/demote! in same state fires once' do
      promotions = 0
      demotions = 0
      elector.on_promote { promotions += 1 }
      elector.on_demote { demotions += 1 }   # fires once at registration (not leader yet)

      elector.promote!
      elector.promote!     # no-op
      elector.demote!
      elector.demote!      # no-op

      expect(promotions).to eq(1)
      expect(demotions).to eq(2)   # one at registration, one on transition
    end

    it 'fires multiple callbacks in registration order' do
      order = []
      elector.on_promote { order << :first }
      elector.on_promote { order << :second }
      elector.promote!
      expect(order).to eq([:first, :second])
    end

    it 'a raising callback does not block sibling callbacks' do
      order = []
      elector.on_promote { raise 'boom' }
      elector.on_promote { order << :ran }
      elector.promote!
      expect(order).to eq([:ran])
    end
  end

  describe Sidereal::Elector::FileSystem do
    let(:lock_path) { File.join(Dir.mktmpdir('sidereal-elector-'), 'leader.lock') }

    after { FileUtils.rm_rf(File.dirname(lock_path)) }

    it 'creates the lock directory if missing' do
      nested = File.join(Dir.mktmpdir, 'a', 'b', 'leader.lock')
      described_class.new(lock_path: nested)
      expect(Dir.exist?(File.dirname(nested))).to be true
    end

    it 'starts as follower; promotes once start fiber acquires the flock' do
      elector = described_class.new(lock_path: lock_path, retry_interval: 0.05)
      promoted = false
      elector.on_promote { promoted = true }

      expect(elector.leader?).to be false

      Sync do |task|
        elector.start(task)
        # Give the election fiber a chance to run.
        sleep 0.1
        expect(elector.leader?).to be true
        expect(promoted).to be true
        task.stop
      end
    end

    it 'second concurrent elector remains follower while first holds the lock' do
      e1 = described_class.new(lock_path: lock_path, retry_interval: 0.05)
      e2 = described_class.new(lock_path: lock_path, retry_interval: 0.05)
      e2_promoted = false
      e2.on_promote { e2_promoted = true }

      Sync do |task|
        e1.start(task)
        sleep 0.1
        expect(e1.leader?).to be true

        e2.start(task)
        sleep 0.2     # plenty of retry cycles
        expect(e2.leader?).to be false
        expect(e2_promoted).to be false

        task.stop
      end
    end

    it 'releases the lock and fires on_demote when the fiber is cancelled' do
      elector = described_class.new(lock_path: lock_path, retry_interval: 0.05)
      demoted = false
      elector.on_promote { demoted = false }   # reset at promotion
      elector.on_demote { demoted = true }     # fires once at registration (still false), then on shutdown

      Sync do |task|
        elector.start(task)
        sleep 0.1
        expect(elector.leader?).to be true
        # demoted was reset to false at promotion via on_promote callback
        expect(demoted).to be false

        task.stop
      end

      # After the parent task stops, the elector's ensure block should
      # have closed the lock file and fired on_demote.
      expect(elector.leader?).to be false
      expect(demoted).to be true
    end

    it 'a follower promotes after the prior leader releases its lock' do
      e1 = described_class.new(lock_path: lock_path, retry_interval: 0.05)
      e2 = described_class.new(lock_path: lock_path, retry_interval: 0.05)

      Sync do |task|
        e1.start(task)
        e2.start(task)
        sleep 0.1
        expect(e1.leader?).to be true
        expect(e2.leader?).to be false

        # Voluntarily step down — releases the flock.
        e1.stop
        sleep 0.2     # let e2's poll cycle pick up the vacancy
        expect(e1.leader?).to be false
        expect(e2.leader?).to be true

        task.stop
      end
    end
  end

  describe 'Sidereal.elector default' do
    it 'defaults to AlwaysLeader' do
      expect(Sidereal.elector).to be_a(Sidereal::Elector::AlwaysLeader)
    end
  end
end
