# frozen_string_literal: true

# The middle-column overlay on /comments/:comment_id. What it offers depends
# on the comment's current state: a pending comment gets the "Start
# moderating" button, a moderating one the verdict controls, and a moderated
# one just shows its verdict.
class DetailCard < Sidereal::Components::BaseComponent
  VIBES = [
    ['positive', 'Positive', Comment::MarkPositive],
    ['neutral',  'Neutral',  Comment::MarkNeutral],
    ['negative', 'Negative', Comment::MarkNegative]
  ].freeze

  # @param historic [Boolean] a frozen snapshot: show the state at that step,
  #   never the controls — you cannot moderate the past.
  def initialize(comment, historic: false)
    @c = comment
    @historic = historic
  end

  def view_template
    if @c.nil?
      render_missing
    else
      article(class: "detail detail--#{@c[:status]}") do
        span(class: 'card__subject') { "Subject: #{Subjects.find(@c[:subject_id])&.title || 'Unknown'}" }
        p(class: 'detail__content') { @c[:content] }
        hr(class: 'detail__rule')
        case @c[:status]
        when nil then render_not_yet
        when 'pending' then @historic ? render_status('In the inbox.') : render_pending
        when 'moderating' then @historic ? render_status('Being moderated.') : render_moderating
        when 'approved' then render_approved
        when 'spam' then render_spam
        end
      end
    end
  end

  private

  # Reached straight after submitting, before the projector has caught up.
  # The page re-renders over SSE as soon as the row lands.
  def render_missing
    article(class: 'detail detail--missing') do
      p(class: 'detail__content') { 'Waiting for this comment to arrive…' }
    end
  end

  # Step 1 of a comment's history is the command, before the event that
  # created it — so there is a stream but no comment yet.
  def render_not_yet
    p(class: 'detail__hint') { 'This comment did not exist yet at this step.' }
  end

  def render_status(text)
    p(class: 'detail__verdict') { text }
  end

  def render_pending
    p(class: 'detail__hint') { 'This comment is in the inbox. Take it to start moderating.' }
    command Comment::StartModeration, class: 'detail__action', key: @c[:comment_id] do |f|
      f.payload_fields(comment_id: @c[:comment_id])
      button(type: :submit, class: 'button button--primary') { 'Start moderating' }
    end
  end

  def render_moderating
    p(class: 'field-label') { 'Vibe' }
    div(class: 'vibes') do
      VIBES.each do |vibe, label, cmd_class|
        command cmd_class, class: 'vibe-form', key: @c[:comment_id] do |f|
          f.payload_fields(comment_id: @c[:comment_id])
          button(type: :submit, class: "vibe vibe--#{vibe}") do
            span(class: 'vibe__dot')
            span(class: 'vibe__label') { label }
          end
        end
      end
    end
    p(class: 'detail__or') { 'Or' }
    command Comment::MarkSpam, class: 'detail__action', key: @c[:comment_id] do |f|
      f.payload_fields(comment_id: @c[:comment_id])
      button(type: :submit, class: 'button button--spam') { 'This is spam' }
    end
  end

  def render_approved
    p(class: 'detail__verdict') do
      span(class: "badge badge--#{@c[:vibe]}") { @c[:vibe] }
      plain ' Approved.'
    end
  end

  def render_spam
    p(class: 'detail__verdict') do
      span(class: 'badge badge--spam') { 'spam' }
      plain ' Classified as spam.'
    end
  end
end
