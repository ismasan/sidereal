# frozen_string_literal: true

module Sidereal
  # Marker for subsystem implementations whose state lives entirely within one
  # process — in-memory queues ({Store::Memory}, {PubSub::Memory}) and
  # always-leader election ({Elector::AlwaysLeader}). They are correct for a
  # single-process deployment but silently break cross-process fan-out once the
  # host forks multiple workers: an SSE update published in one worker never
  # reaches subscribers connected to another, and every process believes it is
  # the leader.
  #
  # {Sidereal.warn_unsafe_topology} uses this marker to warn loudly at startup
  # when any such subsystem is configured alongside a multi-process deployment.
  # Cross-process-safe implementations (the Unix-socket pubsub, the FileSystem
  # elector/store, a DB-backed Sourced store) deliberately do NOT include it.
  module SingleProcess
  end
end
