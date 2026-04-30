# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'tmpdir'
require 'json'
require 'sidereal/store/file_system'

FsStoreCmd = Sidereal::Message.define('fs_store_spec.cmd') do
  attribute :name, Sidereal::Types::String
end

FsStoreOther = Sidereal::Message.define('fs_store_spec.other')

RSpec.describe Sidereal::Store::FileSystem do
  around(:each) do |example|
    Dir.mktmpdir('sidereal-fs-test') do |root|
      @root = root
      example.run
    end
  end

  let(:store) { described_class.new(root: @root, poll_interval: 0.01, sweep_interval: 0.01) }

  describe '#append' do
    it 'returns true' do
      expect(store.append(FsStoreCmd.new(payload: { name: 'a' }))).to be true
    end

    it 'creates a file under pending/' do
      store.append(FsStoreCmd.new(payload: { name: 'a' }))
      pending = Dir.children(File.join(@root, 'pending'))
      expect(pending.size).to eq(1)
      expect(pending.first).to end_with('.json')
    end

    it 'leaves no files in tmp/' do
      store.append(FsStoreCmd.new(payload: { name: 'a' }))
      expect(Dir.children(File.join(@root, 'tmp'))).to be_empty
    end
  end

  describe '#claim_next' do
    it 'yields appended messages' do
      msg = FsStoreCmd.new(payload: { name: 'hello' })
      store.append(msg)

      claimed = claim_one(store)
      expect(claimed).to be_a(FsStoreCmd)
      expect(claimed.payload.name).to eq('hello')
    end

    it 'yields messages in append order' do
      3.times { |i| store.append(FsStoreCmd.new(payload: { name: i.to_s })) }

      claimed = claim_messages(store, 3)
      expect(claimed.map { |m| m.payload.name }).to eq(%w[0 1 2])
    end

    it 'deletes the processing/ file after the block returns' do
      store.append(FsStoreCmd.new(payload: { name: 'a' }))
      claim_one(store)
      expect(Dir.children(File.join(@root, 'processing'))).to be_empty
      expect(Dir.children(File.join(@root, 'pending'))).to be_empty
    end

    it 'survives across store instances (state persists on disk)' do
      producer = described_class.new(root: @root)
      producer.append(FsStoreCmd.new(payload: { name: 'persisted' }))

      consumer = described_class.new(root: @root, poll_interval: 0.01)
      claimed = claim_one(consumer)
      expect(claimed.payload.name).to eq('persisted')
    end

    it 'preserves message id, correlation, and metadata across the round-trip' do
      original = FsStoreCmd.new(
        payload: { name: 'x' },
        metadata: { channel: 'ch1', tag: 'foo' }
      )
      store.append(original)

      claimed = claim_one(store)
      expect(claimed.id).to eq(original.id)
      expect(claimed.correlation_id).to eq(original.correlation_id)
      expect(claimed.metadata).to eq(original.metadata)
    end

    it 'delivers each message to exactly one of two concurrent consumers' do
      messages = 10.times.map { |i| FsStoreCmd.new(payload: { name: i.to_s }) }
      messages.each { |m| store.append(m) }

      claimed_by = { a: [], b: [] }

      Sync do |task|
        store.start(task)
        consumer_a = task.async do
          store.claim_next { |m| claimed_by[:a] << m }
        end
        consumer_b = task.async do
          store.claim_next { |m| claimed_by[:b] << m }
        end

        task.async do
          loop do
            break if claimed_by[:a].size + claimed_by[:b].size == 10
            sleep 0.01
          end
          consumer_a.stop
          consumer_b.stop
        end.wait
      end

      all = claimed_by[:a] + claimed_by[:b]
      expect(all.map(&:id).sort).to eq(messages.map(&:id).sort)
    end
  end

  describe 'sweeper' do
    let(:store) { described_class.new(root: @root, sweep_interval: 0, stale_threshold: 1) }

    def stage_processing_file(content:, pid:, claim_ns:)
      original = "#{Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)}-stale.json"
      processing_name = "#{original}__#{pid}__#{claim_ns}"
      processing_dir = File.join(@root, 'processing')
      FileUtils.mkdir_p(processing_dir)
      path = File.join(processing_dir, processing_name)
      File.write(path, content)
      [path, original]
    end

    it 'returns files claimed by a dead pid back to pending/' do
      payload = JSON.dump(FsStoreCmd.new(payload: { name: 'abandoned' }).to_h)
      _path, original = stage_processing_file(
        content: payload,
        pid: 999_999,
        claim_ns: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      )

      # Drive one iteration of the sweep + claim
      claimed = claim_one(store)
      expect(claimed.payload.name).to eq('abandoned')
      expect(Dir.children(File.join(@root, 'pending'))).to be_empty
      expect(Dir.children(File.join(@root, 'processing'))).to be_empty
    end

    it 'returns files older than stale_threshold even if pid is alive' do
      payload = JSON.dump(FsStoreCmd.new(payload: { name: 'hung' }).to_h)
      old_ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) - (2 * 1_000_000_000) # 2s old
      _path, _original = stage_processing_file(
        content: payload,
        pid: Process.pid, # alive (us)
        claim_ns: old_ns
      )

      claimed = claim_one(store)
      expect(claimed.payload.name).to eq('hung')
    end

    it 'is throttled by sweep_interval' do
      slow_store = described_class.new(root: @root, poll_interval: 0.01, sweep_interval: 60, stale_threshold: 0)
      # Pin last_sweep to now so the next sweep is 60s away.
      slow_store.instance_variable_set(:@last_sweep, Time.now)

      payload = JSON.dump(FsStoreCmd.new(payload: { name: 'stuck' }).to_h)
      stage_processing_file(
        content: payload,
        pid: 999_999,
        claim_ns: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      )

      # Append a fresh pending message so claim_next can make progress.
      slow_store.append(FsStoreCmd.new(payload: { name: 'fresh' }))
      claimed = claim_one(slow_store)
      # Because sweep is throttled, the stale file is NOT recovered;
      # claim_next picks up the freshly appended one only.
      expect(claimed.payload.name).to eq('fresh')
      expect(Dir.children(File.join(@root, 'processing'))).not_to be_empty # stuck file still there
    end
  end

  describe 'cross-process exclusivity' do
    it 'two processes claim disjoint subsets of appended messages' do
      n = 30
      n.times { |i| store.append(FsStoreCmd.new(payload: { name: i.to_s })) }

      child_ids_path = File.join(@root, 'child_ids.json')

      child_pid = fork do
        # Re-instantiate in the child
        child_store = described_class.new(root: @root, poll_interval: 0.01)
        ids = []
        deadline = Time.now + 2.0
        while Time.now < deadline
          claimed_path = child_store.send(:try_claim)
          if claimed_path
            msg = child_store.send(:deserialize, File.read(claimed_path))
            ids << msg.id
            File.unlink(claimed_path)
          else
            sleep 0.01
          end
        end
        File.write(child_ids_path, JSON.dump(ids))
        exit!(0)
      end

      parent_ids = []
      deadline = Time.now + 2.0
      while Time.now < deadline
        claimed_path = store.send(:try_claim)
        if claimed_path
          msg = store.send(:deserialize, File.read(claimed_path))
          parent_ids << msg.id
          File.unlink(claimed_path)
        else
          sleep 0.01
        end
      end

      Process.wait(child_pid)
      child_ids = JSON.parse(File.read(child_ids_path))

      all_ids = parent_ids + child_ids
      expect(all_ids.sort).to eq(all_ids.uniq.sort) # no duplicates
      expect(all_ids.size).to eq(n) # all claimed
      expect(parent_ids).not_to be_empty
      expect(child_ids).not_to be_empty
    end
  end
end
