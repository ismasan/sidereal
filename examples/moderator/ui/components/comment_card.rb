# frozen_string_literal: true

require 'time'

# One comment in a pipeline column. The whole card links to the detail view.
# Approved cards are tinted by vibe; the others stay neutral.
class CommentCard < Sidereal::Components::BaseComponent
  EXCERPT = 90

  def initialize(comment, current: false)
    @c = comment
    @current = current
  end

  def view_template
    classes = ['card', "card--#{@c[:status]}"]
    classes << "card--#{@c[:vibe]}" if @c[:status] == 'approved'
    classes << 'card--current' if @current

    a(href: "/comments/#{@c[:comment_id]}", class: classes.join(' '), id: "card-#{@c[:comment_id]}") do
      span(class: 'card__content') { excerpt }
      span(class: 'card__meta') do
        time(class: 'card__date', datetime: @c[:created_at]) { created_at.strftime('%-d %b %Y, %H:%M') }
        span(class: "pill pill--#{@c[:vibe]}") { @c[:vibe] } if @c[:status] == 'approved'
      end
    end
  end

  private def created_at
    Time.iso8601(@c[:created_at])
  end

  private def excerpt
    text = @c[:content].to_s
    text.length > EXCERPT ? "#{text[0, EXCERPT].rstrip}…" : text
  end
end
