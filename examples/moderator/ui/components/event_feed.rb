# frozen_string_literal: true

# Messages from Sourced's log, newest first. Commands and events both appear,
# tagged, since the demo is about watching the log grow.
#
# Two modes. The board shows the global log across all subjects, where each
# row links to its comment. The detail view shows one comment's own stream,
# where each row links to the state of that comment as of that message — the
# "time travel" links, with arrow navigation in the header.
class EventFeed < Sidereal::Components::BaseComponent
  LIMIT = 25

  def self.recent
    Sourced.store.read_all(limit: LIMIT, order: :desc).messages
  end

  # One comment's whole stream, oldest first: a step number is a position in
  # that history, so the order has to be chronological even though the list
  # renders newest at the top. A partition read rather than a filtered global
  # read, and unlimited, since a single comment's log is a handful of messages.
  def self.for_comment(comment_id)
    Sourced.store
      .read_partition({ comment_id: comment_id }, handled_types: Comment.display_types)
      .messages
  end

  # @param messages [Array<Sourced::Message>] newest first for the global
  #   feed, oldest first when +comment_id+ is given
  # @param scope [String, nil] label shown next to the title
  # @param comment_id [String, nil] turns each row into a step link
  # @param current_step [Integer, nil] the step being viewed; defaults to the
  #   last one, which is what the live page is showing
  def initialize(messages, scope: nil, comment_id: nil, current_step: nil)
    @messages = messages
    @scope = scope
    @comment_id = comment_id
    @current_step = current_step || messages.length
  end

  def view_template
    aside(id: 'event-feed', class: 'feed') do
      header(class: 'feed__header') do
        h2(class: 'feed__title') do
          plain 'Event feed'
          span(class: 'feed__scope') { @scope } if @scope
        end
      end
      render_pagination if time_travel? && @messages.any?

      if @messages.empty?
        p(class: 'feed__empty') { empty_message }
      elsif time_travel?
        ol(class: 'feed__list') do
          # Rendered newest first, numbered oldest first: the top row is the
          # latest message and carries the highest step.
          @messages.each_with_index.to_a.reverse.each do |(msg, index)|
            step = index + 1
            render Row.new(
              msg,
              href: step_href(step),
              step: step,
              highlighted: step == @current_step
            )
          end
        end
      else
        ol(class: 'feed__list') do
          @messages.each { |msg| render Row.new(msg, href: comment_href(msg)) }
        end
      end
    end
  end

  private

  def time_travel? = !@comment_id.nil?

  def step_href(step) = "/comments/#{@comment_id}/#{step}"

  def comment_href(msg)
    id = msg.payload.respond_to?(:comment_id) ? msg.payload.comment_id : nil
    id ? "/comments/#{id}" : nil
  end

  def empty_message
    @scope ? 'No messages for this comment yet.' : 'Nothing yet. Leave a comment to get started.'
  end

  # Step back and forward through the comment's history one message at a time.
  def render_pagination
    div(class: 'feed__pagination') do
      span(class: 'feed__position') { "Step #{@current_step} of #{@messages.length}" }
      pager_link('←', @current_step - 1, enabled: @current_step > 1, title: 'Previous step')
      pager_link('→', @current_step + 1, enabled: @current_step < @messages.length, title: 'Next step')
    end
  end

  def pager_link(label, step, enabled:, title:)
    if enabled
      a(class: 'pager-button', href: step_href(step), title: title) { label }
    else
      span(class: 'pager-button pager-button--disabled', title: title) { label }
    end
  end

  class Row < Sidereal::Components::BaseComponent
    def initialize(msg, href: nil, step: nil, highlighted: false)
      @msg = msg
      @href = href
      @step = step
      @highlighted = highlighted
    end

    def view_template
      kind = @msg.is_a?(Sourced::Command) ? 'command' : 'event'
      classes = ['feed__item', "feed__item--#{kind}"]
      classes << 'feed__item--current' if @highlighted

      li(class: classes.join(' '), id: "feed-#{@msg.id}") do
        if @step
          a(class: 'feed__step', href: @href, title: "View state at step #{@step}") { @step.to_s }
        else
          span(class: 'feed__kind', title: kind) { span(class: 'visually-hidden') { kind } }
        end

        if @href
          a(class: 'feed__type', href: @href) { name }
        else
          span(class: 'feed__type') { name }
        end

        time(class: 'feed__time', datetime: @msg.created_at.iso8601) { @msg.created_at.strftime('%H:%M:%S') }
      end
    end

    private

    # 'comments.marked_spam' → 'MarkedSpam'
    def name
      @msg.type.split('.').last.split('_').map(&:capitalize).join
    end
  end
end
