#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Benchmark for Sidereal::PubSub::Unix throughput and concurrent subscribers.
#
# Each subscriber fiber owns a unique channel ("bench.<i>"). The publisher
# round-robins across channels, publishing one message per subscriber per
# round. Total messages = subscribers × rounds; every message hits exactly
# one subscriber (no fan-out amplification — what we're measuring is the
# raw publish→deliver pipeline, scaled by N concurrent fibers).
#
# Modes:
#   --inproc  publisher and subscribers in the same process. Local delivery
#             dominates (deliver_local before the wire write); the broker
#             fan-out is a no-op because the publisher's own peer is the
#             only one and is excluded from fan-out.
#   --xproc   subscribers in the parent, publisher in a forked child. Frames
#             traverse the socket: publisher → broker (parent) → loopback
#             peer in parent → read loop → deliver_local. This is the
#             realistic cross-process path Sidereal apps see in production.
#
# Each message embeds CLOCK_MONOTONIC at publish time; the subscriber
# computes (receive - publish) for per-message latency. CLOCK_MONOTONIC is
# system-wide on Linux/macOS so the publisher and subscriber clocks are
# directly comparable.
#
# Reported `elapsed` is computed from message timestamps:
#
#   elapsed = max(receive_ns) - min(publish_ns)
#
# i.e. from the moment the first message was published to the moment the
# last one was received. This deliberately excludes the warmup sleep, the
# cross-process startup-coordination lag, and the tail polling sleep — so
# `rate = total / elapsed` is a clean publish-to-deliver throughput.
#
# Usage:
#   bundle exec ruby benchmark/unix_pubsub.rb [options]
#
# Examples:
#   benchmark/unix_pubsub.rb                            # 10 subs × 1000 rounds, in-process
#   benchmark/unix_pubsub.rb -n 50 -m 2000              # 50 subs × 2000 rounds
#   benchmark/unix_pubsub.rb --xproc                    # cross-process
#   benchmark/unix_pubsub.rb --xproc -n 100 -m 5000     # heavier x-process

require 'optparse'
require 'tmpdir'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'sidereal'
require 'sidereal/pubsub/unix'

opts = {
  subscribers: 10,
  rounds:      1_000,
  mode:        :inproc
}

OptionParser.new do |o|
  o.banner = 'Usage: bundle exec ruby benchmark/unix_pubsub.rb [options]'
  o.on('-n', '--subscribers N', Integer, 'Number of subscriber fibers (default 10)') { |n| opts[:subscribers] = n }
  o.on('-m', '--rounds M', Integer, 'Messages published per subscriber (default 1000)') { |n| opts[:rounds] = n }
  o.on('--inproc', 'Single-process loopback (default)') { opts[:mode] = :inproc }
  o.on('--xproc',  'Publisher in a forked child') { opts[:mode] = :xproc }
  o.on('-h', '--help') { puts o; exit }
end.parse!

# Silence the JSON log noise (election INFO lines, transient ECONNREFUSED
# WARN during the startup race) so only the numeric output is on stdout.
# Set CONSOLE_LEVEL=warn or =info to see them.
require 'logger'
Console.logger.level = Logger::ERROR unless ENV['CONSOLE_LEVEL']

BenchMsg = Sidereal::Message.define('bench.event') do
  attribute :seq,        ::Integer
  attribute :publish_ns, ::Integer
end

def now_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
def now_s  = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def percentile(sorted, pct)
  return 0 if sorted.empty?

  i = ((pct / 100.0) * (sorted.size - 1)).round
  sorted[i]
end

def report(label, opts, total, elapsed_s, latencies_ns)
  rate = elapsed_s.zero? ? 0 : (total / elapsed_s)
  sorted = latencies_ns.sort
  printf("%-7s subs=%-4d rounds=%-6d total=%-7d elapsed=%6.3fs rate=%9.0f msg/s",
         label, opts[:subscribers], opts[:rounds], total, elapsed_s, rate)
  unless sorted.empty?
    printf("   latency μs p50=%-7d p95=%-7d p99=%-7d max=%-7d",
           percentile(sorted, 50) / 1_000,
           percentile(sorted, 95) / 1_000,
           percentile(sorted, 99) / 1_000,
           sorted.last / 1_000)
  end
  puts
end

# Use a generous write-queue ceiling so the broker doesn't drop slow peers
# during a heavy benchmark — any drop would skew numbers.
def build(root)
  Sidereal::PubSub::Unix.new(
    socket_path:      File.join(root, 'p.sock'),
    lock_path:        File.join(root, 'p.lock'),
    write_queue_size: 1_000_000
  )
end

def publish_round_robin(pubsub, opts)
  opts[:rounds].times do |seq|
    opts[:subscribers].times do |i|
      pubsub.publish(
        "bench.#{i}",
        BenchMsg.new(payload: { seq: seq, publish_ns: now_ns })
      )
    end
  end
end

# Wire up subscribers, hand control to the caller's block to trigger
# publishing (inline or via cross-process signal), then wait for delivery
# and report. Reported elapsed = max(receive_ns) - min(publish_ns) so the
# warmup, cross-process startup lag, and tail polling are excluded.
def measure(label, opts, pubsub, deadline_s:)
  target = opts[:subscribers] * opts[:rounds]
  received = 0
  latencies = []
  first_publish_ns = nil
  last_receive_ns = nil

  Sync do |task|
    pubsub.start(task)

    channels = opts[:subscribers].times.map { |i| pubsub.subscribe("bench.#{i}") }
    consumers = channels.map do |ch|
      task.async do
        ch.start do |m, _|
          now = now_ns
          received += 1
          publish_ns = m.payload.publish_ns
          first_publish_ns = publish_ns if first_publish_ns.nil? || publish_ns < first_publish_ns
          last_receive_ns = now
          latencies << (now - publish_ns)
        end
      end
    end

    sleep 0.1 # let subscriptions settle (broker has accepted the local peer)

    yield task

    deadline = now_s + deadline_s
    sleep(0.005) until received >= target || now_s > deadline

    channels.each(&:stop)
    consumers.each(&:wait)
  end

  elapsed = first_publish_ns && last_receive_ns ? (last_receive_ns - first_publish_ns) / 1e9 : 0
  report(label, opts, received, elapsed, latencies)
  warn "  WARN: only #{received}/#{target} messages received before timeout" if received < target
end

def run_inproc(opts)
  Dir.mktmpdir(['srl-bench-', ''], '/tmp') do |root|
    pubsub = build(root)
    measure('inproc', opts, pubsub, deadline_s: 60) do |_task|
      publish_round_robin(pubsub, opts)
    end
  end
end

def run_xproc(opts)
  Dir.mktmpdir(['srl-bench-', ''], '/tmp') do |root|
    ready_path = File.join(root, 'subs_ready')

    child = fork do
      pubsub = build(root)
      Sync do |task|
        pubsub.start(task)
        sleep 0.02 until File.exist?(ready_path)
        sleep 0.1 # let our client connection be accepted by the parent's broker
        publish_round_robin(pubsub, opts)
        sleep 0.5 # flush
        task.stop
      end
      exit!(0)
    end

    pubsub = build(root)
    measure('xproc', opts, pubsub, deadline_s: 120) do |_task|
      sleep 0.02 until pubsub.leader? # we forked first → we should win flock
      File.write(ready_path, '1')
    end

    Process.kill('TERM', child) rescue nil
    Process.wait(child)
  end
end

case opts[:mode]
when :inproc then run_inproc(opts)
when :xproc  then run_xproc(opts)
end
