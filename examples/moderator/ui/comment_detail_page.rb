# frozen_string_literal: true

require_relative 'pipeline_page'

# ui:DetailView — the pipeline board with one comment's detail card laid over
# the middle column. Works for a comment in any state; the card decides what
# to offer. Inherits the board's reactions, so verdicts and races between
# moderators show up live.
class CommentDetailPage < PipelinePage
  path '/comments/:comment_id'

  # The comment can be nil for a moment right after submission, before the
  # projector has written its row. The card renders a waiting state and the
  # inherited Projected reaction re-renders the page when the row lands.
  def self.load(params, _ctx)
    comment = CommentsProjector.find(params[:comment_id])
    subject = Subjects.find(comment&.[](:subject_id) || params[:subject_id]) || Subjects.first
    new(
      subject: subject,
      board: CommentsProjector.board_for(subject.id),
      spam_count: CommentsProjector.spam_count(subject.id),
      feed: EventFeed.recent,
      detail: comment
    )
  end

  def default_tab = 'moderating'

  def detail? = true
end
