# frozen_string_literal: true

# The most recent messages in Sourced's global log, newest first, across all
# subjects. Commands and events both appear, tagged, since the demo is about
# watching the log grow.
class EventFeed < Sidereal::Components::BaseComponent
  LIMIT = 25

  def self.recent
    Sourced.store.read_all(limit: LIMIT, order: :desc).messages
  end

  def initialize(messages)
    @messages = messages
  end

  def view_template
    aside(id: 'event-feed', class: 'feed') do
      h2(class: 'feed__title') { 'Event feed' }
      if @messages.empty?
        p(class: 'feed__empty') { 'Nothing yet. Leave a comment to get started.' }
      else
        ol(class: 'feed__list') do
          @messages.each { |msg| render Row.new(msg) }
        end
      end
    end
  end

  class Row < Sidereal::Components::BaseComponent
    def initialize(msg)
      @msg = msg
    end

    def view_template
      kind = @msg.is_a?(Sourced::Command) ? 'command' : 'event'
      li(class: "feed__item feed__item--#{kind}", id: "feed-#{@msg.id}") do
        span(class: 'feed__kind') { kind }
        if comment_id
          a(href: "/comments/#{comment_id}", class: 'feed__type') { name }
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

    def comment_id
      @msg.payload.respond_to?(:comment_id) ? @msg.payload.comment_id : nil
    end
  end
end
