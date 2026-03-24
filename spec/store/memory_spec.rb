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

      claimed = nil
      Sync do
        store.claim_next { |m| claimed = m }
      end

      expect(claimed).to eq(msg)
    end

    it 'yields messages in FIFO order' do
      a = MsgA.new
      b = MsgB.new
      c = MsgC.new
      store.append(a)
      store.append(b)
      store.append(c)

      claimed = []
      Sync do
        3.times { store.claim_next { |m| claimed << m } }
      end

      expect(claimed).to eq([a, b, c])
    end

    it 'blocks until a message is available' do
      claimed = nil

      Sync do |task|
        # Consumer starts first, blocks waiting
        consumer = task.async do
          store.claim_next { |m| claimed = m }
        end

        # Producer appends after consumer is waiting
        task.async do
          store.append(MsgA.new(payload: {}))
        end

        consumer.wait
      end

      expect(claimed).to be_a(MsgA)
    end

    it 'delivers each message to exactly one consumer' do
      messages = 10.times.map { MsgA.new }
      messages.each { |m| store.append(m) }

      claimed_by = { a: [], b: [] }

      Sync do |task|
        consumer_a = task.async do
          10.times do
            store.claim_next { |m| claimed_by[:a] << m }
          rescue Async::Stop
            break
          end
        end

        consumer_b = task.async do
          10.times do
            store.claim_next { |m| claimed_by[:b] << m }
          rescue Async::Stop
            break
          end
        end

        # Wait until all messages are consumed
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
end
