# frozen_string_literal: true

# Cross-partition read model that powers the pipeline board: one row per
# comment, upserted as its events arrive. Mirrors GamesProjector in
# examples/chess.
class CommentsProjector < Sourced::Projector::StateStored
  consumer_group 'comments_projector'
  partition_by :comment_id

  state do |values|
    db = Sourced.store.db
    db[:comments].where(comment_id: values[:comment_id]).first ||
      {
        comment_id: nil,
        subject_id: nil,
        commenter_id: nil,
        content: nil,
        status: nil,
        vibe: 'unknown',
        created_at: nil,
        updated_at: nil
      }
  end

  evolve(Comment::CommentCreated) do |s, e|
    s[:comment_id] = e.payload.comment_id
    s[:subject_id] = e.payload.subject_id
    s[:commenter_id] = e.payload.commenter_id
    s[:content] = e.payload.content
    s[:status] = 'pending'
    s[:created_at] = e.created_at.iso8601
    s[:updated_at] = e.created_at.iso8601
  end

  evolve(Comment::ModerationStarted) do |s, e|
    s[:status] = 'moderating'
    s[:updated_at] = e.created_at.iso8601
  end

  evolve(Comment::MarkedPositive) do |s, e|
    s[:status] = 'approved'
    s[:vibe] = 'positive'
    s[:updated_at] = e.created_at.iso8601
  end

  evolve(Comment::MarkedNegative) do |s, e|
    s[:status] = 'approved'
    s[:vibe] = 'negative'
    s[:updated_at] = e.created_at.iso8601
  end

  evolve(Comment::MarkedNeutral) do |s, e|
    s[:status] = 'approved'
    s[:vibe] = 'neutral'
    s[:updated_at] = e.created_at.iso8601
  end

  evolve(Comment::MarkedSpam) do |s, e|
    s[:status] = 'spam'
    s[:updated_at] = e.created_at.iso8601
  end

  sync do |state:, **|
    next unless state[:comment_id]

    Sourced.store.db[:comments].insert_conflict(:replace).insert(state)
  end

  # Pause after each committed step when SLOWMO=<seconds> is set, so the board
  # can be watched updating one event at a time. Runs post-commit, so no
  # SQLite lock is held while sleeping; the Projected signal below has already
  # been published by the time this runs, so the browser patches, then waits.
  if ENV['SLOWMO']
    after_sync do |**|
      sleep Float(ENV['SLOWMO'])
    end
  end

  # A `Projected` signal (attribute: comment_id) is auto-generated from
  # `partition_by` and published after each committed batch by
  # Sidereal::Integrations::Sourced — routed via Sidereal.channels.for.

  def self.on_reset
    Sourced.store.db[:comments].delete
  end

  # ---- Class-level queries ----

  def self.find(comment_id)
    Sourced.store.db[:comments].where(comment_id:).first
  end

  # Pipeline columns for one subject, or for every subject when +subject_id+
  # is nil. Inbox and moderating are oldest-first (a queue); approved is
  # newest-first (a feed). Spam is only counted.
  def self.board_for(subject_id)
    rows = comments_for(subject_id).exclude(status: 'spam').all
    {
      pending: rows.select { |r| r[:status] == 'pending' }.sort_by { |r| r[:created_at] },
      moderating: rows.select { |r| r[:status] == 'moderating' }.sort_by { |r| r[:updated_at] },
      approved: rows.select { |r| r[:status] == 'approved' }.sort_by { |r| r[:updated_at] }.reverse
    }
  end

  def self.spam_count(subject_id)
    comments_for(subject_id).where(status: 'spam').count
  end

  def self.comments_for(subject_id)
    ds = Sourced.store.db[:comments]
    subject_id ? ds.where(subject_id:) : ds
  end
end
