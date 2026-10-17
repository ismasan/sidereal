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
  # Who took the comment into moderation. Both the human clicking "Start
  # moderating" and the Classifier automation emit the same event, so the
  # actor has to be recorded on it for either side to tell them apart.
  STARTED_BY = %w[moderator classifier].freeze

  # ---- Commands ----

  # commenter_id and subject_name default to blank so the browser form can
  # omit them — `before_command` in the app stamps the session's id, and the
  # app's `handle` block stamps the chosen subject's title, before the command
  # runs. The handler below refuses a blank one of either.
  CreateComment = Sourced::Command.define('comments.create_comment') do
    attribute :comment_id, Sourced::Types::AutoUUID
    attribute :subject_id, Sourced::Types::UUID::V4
    attribute :subject_name, Sourced::Types::String.default('')
    attribute :commenter_id, Sourced::Types::String.default('')
    attribute :content, Sourced::Types::String.present
  end

  StartModeration = Sourced::Command.define('comments.start_moderation') do
    attribute :comment_id, Sourced::Types::UUID::V4
    attribute :started_by, Sourced::Types::String.options(STARTED_BY)
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
    attribute :subject_name, Sourced::Types::String.present
    attribute :commenter_id, Sourced::Types::UUID::V4
    attribute :content, Sourced::Types::String.present
  end

  ModerationStarted = Sourced::Event.define('comments.moderation_started') do
    attribute :comment_id, Sourced::Types::UUID::V4
    attribute :started_by, Sourced::Types::String.options(STARTED_BY)
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

  # ---- Display ----

  # Message types that belong to one comment's stream: its commands and its
  # events. Used as the filter for the per-comment partition read behind the
  # detail view's event feed.
  def self.display_types
    (handled_messages + handled_messages_for_evolve).uniq.map(&:type)
  end

  # ---- Context ----

  State = Struct.new(
    :comment_id,
    :subject_id,
    :subject_name,
    :commenter_id,
    :content,
    :status,   # nil | 'pending' | 'moderating' | 'approved' | 'spam'
    :vibe,     # 'unknown' | 'positive' | 'neutral' | 'negative'
    keyword_init: true
  )

  context do
    State.new(vibe: 'unknown')
  end

  before_evolve do |context, evt|
    context.comment_id ||= evt.payload.comment_id
  end

  evolve(CommentCreated) do |context, evt|
    context.subject_id = evt.payload.subject_id
    context.subject_name = evt.payload.subject_name
    context.commenter_id = evt.payload.commenter_id
    context.content = evt.payload.content
    context.status = 'pending'
  end

  evolve(ModerationStarted) do |context, _evt|
    context.status = 'moderating'
  end

  evolve(MarkedPositive) do |context, _evt|
    context.status = 'approved'
    context.vibe = 'positive'
  end

  evolve(MarkedNegative) do |context, _evt|
    context.status = 'approved'
    context.vibe = 'negative'
  end

  evolve(MarkedNeutral) do |context, _evt|
    context.status = 'approved'
    context.vibe = 'neutral'
  end

  evolve(MarkedSpam) do |context, _evt|
    context.status = 'spam'
  end

  # ---- Command handlers ----

  command(CreateComment) do |context, cmd|
    return if context.status # idempotent — a re-submit of the same id is a silent no-op
    raise 'commenter required' if cmd.payload.commenter_id.to_s.empty?
    raise 'unknown subject' unless Subjects.exists?(cmd.payload.subject_id)
    raise 'subject name required' if cmd.payload.subject_name.to_s.empty?

    event CommentCreated,
      comment_id: cmd.payload.comment_id,
      subject_id: cmd.payload.subject_id,
      subject_name: cmd.payload.subject_name,
      commenter_id: cmd.payload.commenter_id,
      content: cmd.payload.content.strip
  end

  # Two moderators can open the same pending comment and both click "Start
  # moderating". Sourced serializes the two commands on this partition, so
  # the second one sees status 'moderating' and no-ops. If both writes reach
  # the store concurrently instead, the optimistic-lock conflict surfaces
  # through Sidereal's error handling (a failure toast) rather than here.
  command(StartModeration) do |context, cmd|
    return unless context.status == 'pending'

    event ModerationStarted,
      comment_id: cmd.payload.comment_id,
      started_by: cmd.payload.started_by
  end

  command(MarkPositive) do |context, cmd|
    return unless moderating?(context)

    event MarkedPositive, comment_id: cmd.payload.comment_id
  end

  command(MarkNegative) do |context, cmd|
    return unless moderating?(context)

    event MarkedNegative, comment_id: cmd.payload.comment_id
  end

  command(MarkNeutral) do |context, cmd|
    return unless moderating?(context)

    event MarkedNeutral, comment_id: cmd.payload.comment_id
  end

  command(MarkSpam) do |context, cmd|
    return unless moderating?(context)

    event MarkedSpam, comment_id: cmd.payload.comment_id
  end

  # Marking is only valid mid-moderation. Anything else — a stale detail
  # page, a double click after a verdict, a comment that never existed — is
  # a silent no-op: Sourced's default error strategy fails the whole consumer
  # group on a raise, which would halt moderation for every comment over one
  # bad click. Only real invariant breaches (see CreateComment) raise.
  private def moderating?(context) = context.status == 'moderating'
end
