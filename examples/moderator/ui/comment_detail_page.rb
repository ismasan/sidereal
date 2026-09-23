# frozen_string_literal: true

require_relative 'pipeline_page'

# ui:DetailView — the pipeline board with one comment's detail card laid over
# the middle column. Works for a comment in any state; the card decides what
# to offer. Inherits the board's reactions, so verdicts and races between
# moderators show up live.
#
# With a +:step+ param (route +/comments/:comment_id/:step+) it renders a
# frozen snapshot instead: the comment as of the Nth message of its stream,
# replayed from the event log. The feed's step links and arrows point here.
class CommentDetailPage < PipelinePage
  path '/comments/:comment_id'

  # Live: the comment is the projector's row, which can be nil for a moment
  # right after submission, before the projector has written it. The card
  # renders a waiting state and the inherited Projected reaction re-renders
  # the page when the row lands.
  #
  # Historic: the row is ignored and the state is rebuilt by replaying the
  # first +step+ messages through the Comment decider, whose State struct
  # carries the same fields the card reads. The feed always lists the whole
  # history, so you can jump forward and back from any snapshot.
  def self.load(params, _ctx)
    comment_id = params[:comment_id]
    step = parse_step(params[:step])
    messages = EventFeed.for_comment(comment_id)

    comment = step ? replay(comment_id, messages.first(step)) : CommentsProjector.find(comment_id)
    subject = Subjects.find(comment&.[](:subject_id) || params[:subject_id])

    new(
      subject: subject,
      board: CommentsProjector.board_for(subject&.id),
      spam_count: CommentsProjector.spam_count(subject&.id),
      feed: messages,
      detail: comment,
      comment_id: comment_id,
      current_step: step
    )
  end

  # nil when there is no step at all (the live page), 0 for a param that is
  # not a positive integer — which #valid_step? rejects, so junk 404s rather
  # than silently rendering the live view at a historic URL.
  def self.parse_step(raw)
    return nil if raw.nil?

    Integer(raw, 10, exception: false).then { |n| n&.positive? ? n : 0 }
  end

  # The decider is already the event-sourced model of a comment, so replaying
  # its own events through it is the projection — no separate view class. Its
  # State struct converts to the same shape the projector row has, which is
  # what DetailCard reads.
  def self.replay(comment_id, messages)
    return nil if messages.empty?

    Comment.new({ comment_id: comment_id }).evolve(messages).to_h
  end

  def initialize(comment_id:, current_step: nil, **rest)
    super(**rest)
    @comment_id = comment_id
    @current_step = current_step
  end

  attr_reader :current_step

  def historic? = !@current_step.nil?

  # Turns every feed row into a step link.
  def feed_comment_id = @comment_id

  # Guards the route: a step past the end of this comment's history is a 404,
  # as is a non-numeric one.
  def valid_step? = !historic? || (@current_step >= 1 && @current_step <= @feed.length)

  def feed_scope = 'this comment'

  def default_tab = 'moderating'

  def detail? = true

  # A snapshot subscribes to nothing, so live events can't overwrite it.
  def channel_name = historic? ? 'static' : super

  # Suppressing page_key makes Page.subscribe return early, so an SSE connect
  # doesn't immediately re-render the snapshot from current state.
  def page_signals = historic? ? {} : super
end
