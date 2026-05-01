# frozen_string_literal: true

require 'spec_helper'
require 'async'

MsgA = Sidereal::Message.define('store_spec.a')
MsgB = Sidereal::Message.define('store_spec.b')
MsgC = Sidereal::Message.define('store_spec.c')

RSpec.describe Sidereal::Store::Memory do
  let(:store) { described_class.new }

  describe '#append' do
    it 'returns true' do
      msg = MsgA.new
      expect(store.append(msg)).to be true
    end
  end

  describe '#claim_next' do
    it 'yields the appended message' do
      msg = MsgA.new
      store.append(msg)

      expect(claim_one(store)).to eq(msg)
    end

    it 'yields messages in FIFO order' do
      a = MsgA.new
      b = MsgB.new
      c = MsgC.new
      store.append(a)
      store.append(b)
      store.append(c)

      expect(claim_messages(store, 3)).to eq([a, b, c])
    end

    it 'blocks until a message is available' do
      claimed = nil

      Sync do |task|
        # Consumer starts first, blocks waiting
        consumer = task.async do
          store.claim_next do |m, _meta|
            claimed = m
            Sidereal::Store::Result::Ack
          end
        end

        # Producer appends after consumer is waiting
        task.async do
          store.append(MsgA.new(payload: {}))
        end

        task.async do
          loop do
            break if claimed
            task.yield
          end
          consumer.stop
        end.wait
      end

      expect(claimed).to be_a(MsgA)
    end

    it 'delivers each message to exactly one consumer' do
      messages = 10.times.map { MsgA.new }
      messages.each { |m| store.append(m) }

      claimed_by = { a: [], b: [] }

      Sync do |task|
        consumer_a = task.async do
          store.claim_next do |m, _meta|
            claimed_by[:a] << m
            Sidereal::Store::Result::Ack
          end
        end

        consumer_b = task.async do
          store.claim_next do |m, _meta|
            claimed_by[:b] << m
            Sidereal::Store::Result::Ack
          end
        end

        # Wait until all messages are consumed, then stop both consumers
        task.async do
          loop do
            break if claimed_by[:a].size + claimed_by[:b].size == 10
            task.yield
          end
          consumer_a.stop
          consumer_b.stop
        end.wait
      end

      all_claimed = claimed_by[:a] + claimed_by[:b]
      expect(all_claimed.size).to eq(10)
      expect(all_claimed.uniq.size).to eq(10)
      expect(all_claimed.sort_by(&:id)).to match_array(messages.sort_by(&:id))
    end
  end

  describe '#claim_next meta' do
    it 'yields meta.attempt == 1 on first claim' do
      store.append(MsgA.new)

      meta = nil
      Sync do |task|
        consumer = task.async do
          store.claim_next do |_m, m|
            meta = m
            Sidereal::Store::Result::Ack
          end
        end
        task.async do
          loop do
            break if meta
            task.yield
          end
          consumer.stop
        end.wait
      end

      expect(meta.attempt).to eq(1)
    end

    it 'yields meta.first_appended_at set to the time of #append' do
      before = Time.now
      store.append(MsgA.new)
      after = Time.now

      meta = nil
      Sync do |task|
        consumer = task.async do
          store.claim_next do |_m, m|
            meta = m
            Sidereal::Store::Result::Ack
          end
        end
        task.async do
          loop do
            break if meta
            task.yield
          end
          consumer.stop
        end.wait
      end

      expect(meta.first_appended_at).to be_between(before, after).inclusive
    end
  end

  describe '#claim_next result handling' do
    # Drain one message from the store with the given block return,
    # asserting the consumer does not see the same message twice.
    def claim_with(store, &)
      seen = []
      Sync do |task|
        consumer = task.async do
          store.claim_next do |m, meta|
            seen << m
            yield(m, meta)
          end
        end
        task.async do
          loop do
            break if seen.size >= 1
            task.yield
          end
          # give the loop one more tick to confirm no second yield
          5.times { task.yield }
          consumer.stop
        end.wait
      end
      seen
    end

    it 'Result::Ack drops the message (no further claim)' do
      store.append(MsgA.new)
      seen = claim_with(store) { |_, _| Sidereal::Store::Result::Ack }
      expect(seen.size).to eq(1)
    end

    it 'Result::Retry logs WARN and acks (Memory does not support retry)' do
      store.append(MsgA.new)
      seen = claim_with(store) do |_, _|
        Sidereal::Store::Result::Retry.new(at: Time.now + 60)
      end
      expect(seen.size).to eq(1)
    end

    it 'Result::Fail logs WARN and drops the message' do
      store.append(MsgA.new)
      seen = claim_with(store) do |_, _|
        Sidereal::Store::Result::Fail.new(error: RuntimeError.new('boom'))
      end
      expect(seen.size).to eq(1)
    end

    it 'malformed return value logs WARN and acks' do
      store.append(MsgA.new)
      seen = claim_with(store) { |_, _| :something_unexpected }
      expect(seen.size).to eq(1)
    end
  end
end
