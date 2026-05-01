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

    it 'creates a file under ready/' do
      store.append(FsStoreCmd.new(payload: { name: 'a' }))
      ready = Dir.children(File.join(@root, 'ready'))
      expect(ready.size).to eq(1)
      expect(ready.first).to end_with('.json')
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
      expect(Dir.children(File.join(@root, 'ready'))).to be_empty
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

    it 'returns files claimed by a dead pid back to ready/' do
      payload = JSON.dump(FsStoreCmd.new(payload: { name: 'abandoned' }).to_h)
      _path, original = stage_processing_file(
        content: payload,
        pid: 999_999,
        claim_ns: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      )

      # Drive one iteration of the sweep + claim
      claimed = claim_one(store)
      expect(claimed.payload.name).to eq('abandoned')
      expect(Dir.children(File.join(@root, 'ready'))).to be_empty
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

      # Append a fresh ready message so claim_next can make progress.
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

  describe 'scheduled delivery' do
    let(:store) do
      described_class.new(
        root: @root,
        poll_interval: 0.01,
        scheduler_interval: 0.05,
        sweep_interval: 60
      )
    end

    it 'routes a future-dated message to scheduled/ on append' do
      msg = FsStoreCmd.new(payload: { name: 'later' }).at(Time.now + 5)
      store.append(msg)
      expect(Dir.children(File.join(@root, 'scheduled')).size).to eq(1)
      expect(Dir.children(File.join(@root, 'ready'))).to be_empty
    end

    it 'routes a present-dated message to ready/ on append' do
      store.append(FsStoreCmd.new(payload: { name: 'now' }))
      expect(Dir.children(File.join(@root, 'ready')).size).to eq(1)
      expect(Dir.children(File.join(@root, 'scheduled'))).to be_empty
    end

    it 'promotes scheduled messages once their created_at has passed' do
      msg = FsStoreCmd.new(payload: { name: 'soon' }).at(Time.now + 0.2)
      store.append(msg)

      claimed = claim_one(store) # blocks until scheduler promotes + poller claims
      expect(claimed.payload.name).to eq('soon')
      expect(claimed.created_at).to be <= Time.now
    end

    it 'does not block immediate messages on far-future scheduled ones' do
      far_future = FsStoreCmd.new(payload: { name: 'far' }).at(Time.now + 3600)
      store.append(far_future)
      store.append(FsStoreCmd.new(payload: { name: 'immediate' }))

      claimed = claim_one(store)
      expect(claimed.payload.name).to eq('immediate')
    end

    it 'promotes due scheduled messages in due-order' do
      t0 = Time.now
      store.append(FsStoreCmd.new(payload: { name: 'third' }).at(t0 + 0.6))
      store.append(FsStoreCmd.new(payload: { name: 'first' }).at(t0 + 0.2))
      store.append(FsStoreCmd.new(payload: { name: 'second' }).at(t0 + 0.4))

      claimed = claim_messages(store, 3)
      expect(claimed.map { |m| m.payload.name }).to eq(%w[first second third])
    end

    it 'preserves scheduled state across store instances on disk' do
      producer = described_class.new(root: @root)
      producer.append(FsStoreCmd.new(payload: { name: 'persisted' }).at(Time.now + 0.2))
      expect(Dir.children(File.join(@root, 'scheduled')).size).to eq(1)

      consumer = described_class.new(
        root: @root,
        poll_interval: 0.01,
        scheduler_interval: 0.05
      )
      claimed = claim_one(consumer)
      expect(claimed.payload.name).to eq('persisted')
    end
  end

  describe 'retry/fail/meta' do
    # Drive one claim, yield (msg, meta) to the test block, use its
    # return as the Result, then stop. Returns [msg, meta].
    def one_claim(store)
      captured = nil
      Sync do |task|
        store.start(task)
        consumer = task.async do
          store.claim_next do |m, meta|
            captured = [m, meta]
            yield(m, meta)
          end
        end
        task.async do
          loop do
            break if captured
            sleep 0.01
          end
          # let the store finish handling the result
          sleep 0.05
          consumer.stop
        end.wait
      end
      captured
    end

    describe 'meta' do
      it 'attempt is 1 on first claim' do
        store.append(FsStoreCmd.new(payload: { name: 'x' }))
        _, meta = one_claim(store) { Sidereal::Store::Result::Ack }
        expect(meta.attempt).to eq(1)
      end

      it 'first_appended_at falls between before and after the append call' do
        before = Time.now
        store.append(FsStoreCmd.new(payload: { name: 'x' }))
        after = Time.now
        _, meta = one_claim(store) { Sidereal::Store::Result::Ack }
        expect(meta.first_appended_at).to be_between(before, after).inclusive
      end
    end

    describe 'Result::Retry' do
      it 'moves the message to scheduled/ with attempt bumped to 2' do
        store.append(FsStoreCmd.new(payload: { name: 'x' }))
        retry_at = Time.now + 5

        one_claim(store) { Sidereal::Store::Result::Retry.new(at: retry_at) }

        expect(Dir.children(File.join(@root, 'processing'))).to be_empty
        expect(Dir.children(File.join(@root, 'ready'))).to be_empty
        expect(Dir.children(File.join(@root, 'dead'))).to be_empty

        scheduled = Dir.children(File.join(@root, 'scheduled'))
        expect(scheduled.size).to eq(1)

        parts = described_class.parse_filename(scheduled.first)
        expect(parts[:attempt]).to eq(2)
        expected_ns = retry_at.tv_sec * 1_000_000_000 + retry_at.tv_nsec
        expect(parts[:not_before_ns]).to eq(expected_ns)
      end

      it 'preserves first_append_ns across retry' do
        store.append(FsStoreCmd.new(payload: { name: 'x' }))
        original = described_class.parse_filename(Dir.children(File.join(@root, 'ready')).first)

        one_claim(store) { Sidereal::Store::Result::Retry.new(at: Time.now + 5) }

        retried = described_class.parse_filename(Dir.children(File.join(@root, 'scheduled')).first)
        expect(retried[:first_append_ns]).to eq(original[:first_append_ns])
      end

      it 'leaves the file body byte-identical' do
        store.append(FsStoreCmd.new(payload: { name: 'x' }))
        original_body = File.read(
          File.join(@root, 'ready', Dir.children(File.join(@root, 'ready')).first)
        )

        one_claim(store) { Sidereal::Store::Result::Retry.new(at: Time.now + 5) }

        retried_body = File.read(
          File.join(@root, 'scheduled', Dir.children(File.join(@root, 'scheduled')).first)
        )
        expect(retried_body).to eq(original_body)
      end

      it 'second claim observes meta.attempt == 2 with first_appended_at preserved' do
        fast_store = described_class.new(
          root: @root,
          poll_interval: 0.01,
          scheduler_interval: 0.05
        )
        fast_store.append(FsStoreCmd.new(payload: { name: 'x' }))

        metas = []
        Sync do |task|
          fast_store.start(task)
          consumer = task.async do
            fast_store.claim_next do |_m, meta|
              metas << meta
              if metas.size == 1
                Sidereal::Store::Result::Retry.new(at: Time.now + 0.1)
              else
                Sidereal::Store::Result::Ack
              end
            end
          end
          task.async do
            loop do
              break if metas.size >= 2
              sleep 0.01
            end
            consumer.stop
          end.wait
        end

        expect(metas[0].attempt).to eq(1)
        expect(metas[1].attempt).to eq(2)
        expect(metas[1].first_appended_at).to eq(metas[0].first_appended_at)
      end
    end

    describe 'Result::Fail' do
      it 'moves the message to dead/ and writes a sidecar' do
        store.append(FsStoreCmd.new(payload: { name: 'x' }))

        one_claim(store) do
          Sidereal::Store::Result::Fail.new(error: RuntimeError.new('boom'))
        end

        expect(Dir.children(File.join(@root, 'processing'))).to be_empty
        expect(Dir.children(File.join(@root, 'ready'))).to be_empty
        expect(Dir.children(File.join(@root, 'scheduled'))).to be_empty

        dead = Dir.children(File.join(@root, 'dead'))
        expect(dead.size).to eq(2)
        expect(dead.count { |n| n.end_with?('.error.json') }).to eq(1)
        expect(dead.count { |n| !n.end_with?('.error.json') }).to eq(1)
      end

      it 'sidecar contains exception class, message, and backtrace' do
        store.append(FsStoreCmd.new(payload: { name: 'x' }))
        captured_ex = begin
          raise 'boom'
        rescue StandardError => e
          e
        end

        one_claim(store) { Sidereal::Store::Result::Fail.new(error: captured_ex) }

        sidecar_name = Dir.children(File.join(@root, 'dead')).find { |n| n.end_with?('.error.json') }
        contents = JSON.parse(File.read(File.join(@root, 'dead', sidecar_name)))
        expect(contents['class']).to eq('RuntimeError')
        expect(contents['message']).to eq('boom')
        expect(contents['backtrace']).to be_an(Array)
        expect(contents['backtrace']).not_to be_empty
      end

      it 'leaves the message body byte-identical in dead/' do
        store.append(FsStoreCmd.new(payload: { name: 'x' }))
        original_body = File.read(
          File.join(@root, 'ready', Dir.children(File.join(@root, 'ready')).first)
        )

        one_claim(store) do
          Sidereal::Store::Result::Fail.new(error: RuntimeError.new('boom'))
        end

        msg_name = Dir.children(File.join(@root, 'dead')).find { |n| !n.end_with?('.error.json') }
        dead_body = File.read(File.join(@root, 'dead', msg_name))
        expect(dead_body).to eq(original_body)
      end
    end

    describe 'malformed return value' do
      it 'unlinks the file (treats as ack)' do
        store.append(FsStoreCmd.new(payload: { name: 'x' }))

        one_claim(store) { :something_unexpected }

        expect(Dir.children(File.join(@root, 'processing'))).to be_empty
        expect(Dir.children(File.join(@root, 'ready'))).to be_empty
        expect(Dir.children(File.join(@root, 'scheduled'))).to be_empty
        expect(Dir.children(File.join(@root, 'dead'))).to be_empty
      end
    end

    describe '#requeue' do
      # Drive a Result::Fail and return the dead message's basename.
      def fail_and_get_dead_name(store)
        store.append(FsStoreCmd.new(payload: { name: 'x' }))
        one_claim(store) do
          Sidereal::Store::Result::Fail.new(error: RuntimeError.new('boom'))
        end
        Dir.children(File.join(@root, 'dead')).find { |n| !n.end_with?('.error.json') }
      end

      it 'moves the message file from dead/ to ready/ and removes the sidecar' do
        dead_name = fail_and_get_dead_name(store)
        expect(Dir.children(File.join(@root, 'dead')).size).to eq(2) # message + sidecar

        store.requeue(dead_name)

        expect(Dir.children(File.join(@root, 'dead'))).to be_empty
        expect(Dir.children(File.join(@root, 'ready')).size).to eq(1)
      end

      it 'resets attempt to 1 in the new filename' do
        dead_name = fail_and_get_dead_name(store)

        store.requeue(dead_name)

        ready_name = Dir.children(File.join(@root, 'ready')).first
        parts = described_class.parse_filename(ready_name)
        expect(parts[:attempt]).to eq(1)
      end

      it 'preserves first_append_ns from the original' do
        dead_name = fail_and_get_dead_name(store)
        original_first_append = described_class.parse_filename(dead_name)[:first_append_ns]

        store.requeue(dead_name)

        ready_name = Dir.children(File.join(@root, 'ready')).first
        expect(described_class.parse_filename(ready_name)[:first_append_ns]).to eq(original_first_append)
      end

      it 'sets not_before_ns to approximately now' do
        dead_name = fail_and_get_dead_name(store)
        before_ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)

        store.requeue(dead_name)
        after_ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)

        ready_name = Dir.children(File.join(@root, 'ready')).first
        not_before = described_class.parse_filename(ready_name)[:not_before_ns]
        expect(not_before).to be_between(before_ns, after_ns).inclusive
      end

      it 'returns the new path under ready/' do
        dead_name = fail_and_get_dead_name(store)

        result = store.requeue(dead_name)

        expect(result).to eq(File.join(@root, 'ready', Dir.children(File.join(@root, 'ready')).first))
        expect(File.exist?(result)).to be true
      end

      it 'works when no sidecar exists for the dead message' do
        dead_name = fail_and_get_dead_name(store)
        File.unlink(File.join(@root, 'dead', "#{dead_name}.error.json"))
        # only the message file remains in dead/

        expect { store.requeue(dead_name) }.not_to raise_error
        expect(Dir.children(File.join(@root, 'dead'))).to be_empty
        expect(Dir.children(File.join(@root, 'ready')).size).to eq(1)
      end

      it 'strips path components and uses the basename' do
        dead_name = fail_and_get_dead_name(store)

        # Any path-like input (relative or absolute) is reduced to its
        # basename and resolved against the configured dead/ directory.
        expect { store.requeue("dead/#{dead_name}") }.not_to raise_error
        expect(Dir.children(File.join(@root, 'ready')).size).to eq(1)
      end

      it 'raises ArgumentError when the file does not exist in dead/' do
        expect { store.requeue('missing.json') }.to raise_error(ArgumentError, /not found in dead/)
      end
    end
  end
end
