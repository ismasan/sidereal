# frozen_string_literal: true

require_relative 'components/subject_picker'
require_relative 'components/comment_card'
require_relative 'components/detail_card'
require_relative 'components/event_feed'

# ui:PipelineView — the three-column moderation board for one subject (or
# every subject when none is picked), plus the global event feed. Re-rendered whole on every comment event (so the
# feed stays live) and on every projector commit (so the columns do).
class PipelinePage < Sidereal::Page
  path '/comments'

  on CommentsProjector::Projected,
     Comment::CommentCreated,
     Comment::ModerationStarted,
     Comment::MarkedPositive,
     Comment::MarkedNeutral,
     Comment::MarkedNegative,
     Comment::MarkedSpam do |_evt|
    browser.patch_elements load(params)
  end

  COLUMNS = [
    [:pending, 'Inbox'],
    [:moderating, 'Moderating'],
    [:approved, 'Moderated']
  ].freeze

  # +subject+ is nil for the unfiltered board.
  def self.load(params, _ctx)
    subject = Subjects.find(params[:subject_id])
    new(
      subject: subject,
      board: CommentsProjector.board_for(subject&.id),
      spam_count: CommentsProjector.spam_count(subject&.id),
      feed: EventFeed.recent
    )
  end

  def initialize(subject:, board:, spam_count:, feed:, detail: nil)
    @subject = subject
    @board = board
    @spam_count = spam_count
    @feed = feed
    @detail = detail
  end

  # Every comment's channel plus the projector's Projected signal.
  def channel_name = 'comments.>'

  # Which column the phone layout opens on. `__ifmissing` keeps a tab the
  # moderator picked across SSE re-renders.
  def default_tab = 'pending'

  def detail? = !@detail.nil?

  # Query string carrying the current subject filter, empty when unfiltered.
  def subject_query = @subject ? "?subject_id=#{@subject.id}" : ''

  # Labels the feed when it is showing one comment rather than the whole log.
  def feed_scope = nil

  # The board's feed is the global log: no step links, no snapshot.
  def feed_comment_id = nil
  def current_step = nil
  def historic? = false

  def view_template
    div(
      id: 'pipeline-page',
      class: 'pipeline',
      data: { 'signals__ifmissing' => { tab: default_tab }.to_json }
    ) do
      div(class: 'pipeline__main') do
        header(class: 'topbar') do
          a(href: '/', class: 'brand') do
            span(class: 'brand__mark', aria_hidden: true)
            plain 'Moderator'
          end
          span(class: 'topbar__divider', aria_hidden: true)
          render SubjectPicker.new(subject: @subject, action: '/comments')
          nav(class: 'topbar__nav') do
            a(href: "/comments#{subject_query}", class: 'button button--ghost') { 'Back to board' } if detail?
            a(href: "/#{subject_query}", class: 'button') { 'Comment box' }
          end
        end

        if historic?
          p(class: 'historic-tag') do
            plain "Viewing this comment as it was at step #{current_step}."
            a(href: "/comments/#{feed_comment_id}") { 'Back to live' }
          end
        end

        div(class: 'board-area') do
          nav(class: 'tabs', aria_label: 'Pipeline stage') do
            COLUMNS.each do |key, label|
              button(
                type: 'button',
                class: 'tab',
                data: { 'on:click' => "$tab = '#{key}'", 'class:is-active' => "$tab === '#{key}'" }
              ) do
                plain label
                span(class: 'tab__count') { @board[key].length.to_s }
              end
            end
          end

          div(class: 'board') do
            COLUMNS.each do |key, label|
              section(
                class: "column column--#{key}",
                data: { 'class:is-active' => "$tab === '#{key}'" }
              ) do
                h2(class: 'column__title') do
                  span(class: 'column__dot', aria_hidden: true)
                  plain label
                  span(class: 'column__count') { @board[key].length.to_s }
                end
                div(class: 'column__body') do
                  if key == :moderating && detail?
                    render DetailCard.new(@detail, historic: historic?)
                  else
                    render_cards(@board[key])
                  end
                end
              end
            end
          end

          footer(class: 'spam-count') do
            strong(class: 'spam-count__number') { @spam_count.to_s }
            plain ' marked as spam'
          end
        end
      end

      render EventFeed.new(
        @feed,
        scope: feed_scope,
        comment_id: feed_comment_id,
        current_step: current_step
      )
    end
  end

  private def render_cards(comments)
    if comments.empty?
      p(class: 'column__empty') { 'Nothing here.' }
    else
      comments.each do |c|
        render CommentCard.new(c, current: !@detail.nil? && @detail[:comment_id] == c[:comment_id])
      end
    end
  end
end
