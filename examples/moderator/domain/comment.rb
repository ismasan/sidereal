# frozen_string_literal: true

require_relative 'subjects'

# Event-sourced comment moving through the moderation pipeline:
#
#   pending → moderating → approved (with a vibe)
#                        → spam
#
# Every transition is a moderator's click; there are no automations yet.
class Comment < Sourced::Decider
  consumer_group 'comments'
  partition_by :comment_id

  STATUSES = %w[pending moderating approved spam].freeze
  VIBES = %w[unknown positive neutral negative].freeze

  # ---- Commands ----

  # commenter_id defaults to blank so the browser form can omit it —
  # `before_command` in the app stamps the session's id before the command
  # runs. The handler below refuses a blank one.
  CreateComment = Sourced::Command.define('comments.create_comment') do
    attribute :comment_id, Sourced::Types::AutoUUID
    attribute :subject_id, Sourced::Types::UUID::V4
    attribute :commenter_id, Sourced::Types::String.default('')
    attribute :content, Sourced::Types::String.present
  end

  StartModeration = Sourced::Command.define('comments.start_moderation') do
    attribute :comment_id, Sourced::Types::UUID::V4
  end

  MarkPositive = Sourced::Command.define('comments.mark_positive') do
    attribute :comment_id, Sourced::Types::UUID::V4
  end

  MarkNegative = Sourced::Command.define('comments.mark_negative') do
    attribute :comment_id, Sourced::Types::UUID::V4
  end

  MarkNeutral = Sourced::Command.define('comments.mark_neutral') do
    attribute :comment_id, Sourced::Types::UUID::V4
  end

  MarkSpam = Sourced::Command.define('comments.mark_spam') do
    attribute :comment_id, Sourced::Types::UUID::V4
  end

  # ---- Events ----

  CommentCreated = Sourced::Event.define('comments.comment_created') do
    attribute :comment_id, Sourced::Types::UUID::V4
    attribute :subject_id, Sourced::Types::UUID::V4
    attribute :commenter_id, Sourced::Types::UUID::V4
    attribute :content, Sourced::Types::String.present
  end

  ModerationStarted = Sourced::Event.define('comments.moderation_started') do
    attribute :comment_id, Sourced::Types::UUID::V4
  end

  MarkedPositive = Sourced::Event.define('comments.marked_positive') do
    attribute :comment_id, Sourced::Types::UUID::V4
  end

  MarkedNegative = Sourced::Event.define('comments.marked_negative') do
    attribute :comment_id, Sourced::Types::UUID::V4
  end

  MarkedNeutral = Sourced::Event.define('comments.marked_neutral') do
    attribute :comment_id, Sourced::Types::UUID::V4
  end

  MarkedSpam = Sourced::Event.define('comments.marked_spam') do
    attribute :comment_id, Sourced::Types::UUID::V4
  end

  # ---- State ----

  State = Struct.new(
    :comment_id,
    :subject_id,
    :commenter_id,
    :content,
    :status,   # nil | 'pending' | 'moderating' | 'approved' | 'spam'
    :vibe,     # 'unknown' | 'positive' | 'neutral' | 'negative'
    keyword_init: true
  )

  state do |values|
    State.new(comment_id: values[:comment_id], vibe: 'unknown')
  end

  evolve(CommentCreated) do |s, e|
    s.subject_id = e.payload.subject_id
    s.commenter_id = e.payload.commenter_id
    s.content = e.payload.content
    s.status = 'pending'
  end

  evolve(ModerationStarted) do |s, _e|
    s.status = 'moderating'
  end

  evolve(MarkedPositive) do |s, _e|
    s.status = 'approved'
    s.vibe = 'positive'
  end

  evolve(MarkedNegative) do |s, _e|
    s.status = 'approved'
    s.vibe = 'negative'
  end

  evolve(MarkedNeutral) do |s, _e|
    s.status = 'approved'
    s.vibe = 'neutral'
  end

  evolve(MarkedSpam) do |s, _e|
    s.status = 'spam'
  end

  # ---- Command handlers ----

  command(CreateComment) do |state, cmd|
    return if state.status # idempotent — a re-submit of the same id is a silent no-op
    raise 'commenter required' if cmd.payload.commenter_id.to_s.empty?
    raise 'unknown subject' unless Subjects.exists?(cmd.payload.subject_id)

    event CommentCreated,
      comment_id: cmd.payload.comment_id,
      subject_id: cmd.payload.subject_id,
      commenter_id: cmd.payload.commenter_id,
      content: cmd.payload.content.strip
  end

  # Two moderators can open the same pending comment and both click "Start
  # moderating". Sourced serializes the two commands on this partition, so
  # the second one sees status 'moderating' and no-ops. If both writes reach
  # the store concurrently instead, the optimistic-lock conflict surfaces
  # through Sidereal's error handling (a failure toast) rather than here.
  command(StartModeration) do |state, cmd|
    return unless state.status == 'pending'

    event ModerationStarted, comment_id: cmd.payload.comment_id
  end

  command(MarkPositive) do |state, cmd|
    return unless moderating?(state)

    event MarkedPositive, comment_id: cmd.payload.comment_id
  end

  command(MarkNegative) do |state, cmd|
    return unless moderating?(state)

    event MarkedNegative, comment_id: cmd.payload.comment_id
  end

  command(MarkNeutral) do |state, cmd|
    return unless moderating?(state)

    event MarkedNeutral, comment_id: cmd.payload.comment_id
  end

  command(MarkSpam) do |state, cmd|
    return unless moderating?(state)

    event MarkedSpam, comment_id: cmd.payload.comment_id
  end

  # Marking is only valid mid-moderation. Anything else — a stale detail
  # page, a double click after a verdict, a comment that never existed — is
  # a silent no-op: Sourced's default error strategy fails the whole consumer
  # group on a raise, which would halt moderation for every comment over one
  # bad click. Only real invariant breaches (see CreateComment) raise.
  private def moderating?(state) = state.status == 'moderating'
end
