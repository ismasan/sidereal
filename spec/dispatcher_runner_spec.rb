# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::DispatcherRunner do
  # Opaque sentinel — the runner only threads it through to its targets.
  let(:task) { Object.new }
  let(:events) { [] }

  # A started root with a deferred 'dispatcher', which records its start and
  # stop hooks, and a 'monitor' depending on it.
  let(:config) do
    log = events
    Sourced::Component.new.tap do |c|
      c.declare('dispatcher')
      c.component!('dispatcher') do
        start { |_, t| log << [:start, t] }
        stop { |_| log << [:stop] }
      end
      c.defer('dispatcher')
      c.declare('monitor')
      c.component!('monitor', ['dispatcher']) { start { |_, _| log << [:start_monitor] } }
      c.start!(task)
    end
  end

  # Elector that starts as follower and lets the spec drive transitions
  # through the same promote!/demote! the real electors call.
  let(:elector) do
    Class.new do
      include Sidereal::Elector::Callbacks
      define_method(:initialize) { @leader = false }
      define_method(:leader?) { @leader }
      public :promote!, :demote!
    end.new
  end

  def runner(process) = described_class.new(config:, targets: ['dispatcher'], elector:, process:)

  def starts = events.count { |e| e.first == :start }
  def stops = events.count([:stop])

  describe 'process: :all' do
    subject(:all) { runner(:all) }

    it 'starts its targets at once, even on a follower, threading the task, and what depends on them' do
      expect(all.start(task)).to be(all)

      expect(events).to eq([[:start, task], [:start_monitor]])
      expect(all).to be_running
      expect(config.node('dispatcher').status).to eq(:started)
    end

    it 'ignores the elector' do
      all.start(task)
      elector.promote!
      elector.demote!

      expect([starts, stops]).to eq([1, 0])
    end

    it 'stops its targets from #stop, once' do
      all.start(task)
      all.stop
      all.stop

      expect(stops).to eq(1)
      expect(all).not_to be_running
      expect(config.node('dispatcher').status).to eq(:stopped)
    end
  end

  describe 'process: :leader' do
    subject(:leader) { runner(:leader) }

    it 'does not start its targets on a follower' do
      leader.start(task)

      expect(starts).to eq(0)
      expect(leader).not_to be_running
    end

    it 'starts them once on promotion' do
      leader.start(task)
      elector.promote!
      elector.promote! # same state: the elector does not re-fire

      expect(events).to eq([[:start, task], [:start_monitor]])
    end

    it 'stops them on demotion, and starts them again on re-promotion' do
      leader.start(task)
      elector.promote!
      elector.demote!
      expect(stops).to eq(1)

      elector.promote!
      expect(starts).to eq(2)
      expect(config.node('monitor').status).to eq(:started)
    end

    it 'stops nothing from #stop while a follower' do
      leader.start(task)
      leader.stop

      expect(stops).to eq(0)
    end

    it 'does not start them again on a promotion after #stop' do
      leader.start(task)
      leader.stop
      elector.promote!

      expect(starts).to eq(0)
    end

    it 'behaves like :all under an elector that is leader from construction' do
      always = described_class.new(config:, targets: ['dispatcher'], elector: Sidereal::Elector::AlwaysLeader.new,
                                   process: :leader)
      always.start(task)

      expect(events).to eq([[:start, task], [:start_monitor]])
    end
  end

  it 'refuses targets that are not deferred, which the root would start in every process' do
    root = Sourced::Component.new.tap do |c|
      c.declare('other') { :other }
      c.start!
    end
    undeferred = described_class.new(config: root, targets: ['other'], elector:, process: :all)

    expect { undeferred.start(task) }.to raise_error(ArgumentError, /other must be deferred/)
  end

  it 'rejects an unknown process at construction' do
    expect { runner(:some) }.to raise_error(Plumb::ParseError)
  end
end
