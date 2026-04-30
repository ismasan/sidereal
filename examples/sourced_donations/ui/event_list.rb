# frozen_string_literal: true

class EventList < Sidereal::Components::BaseComponent
  def initialize(messages:, campaign_id:, donation_id:, current_step: nil)
    @messages = messages
    @campaign_id = campaign_id
    @donation_id = donation_id
    @current_step = current_step || messages.length
  end

  def view_template
    aside(id: 'event-list') do
      header(class: 'event-list__header') do
        h2 { 'History' }
        render_pagination if @messages.any?
        span(class: 'event-list__count') { "#{@messages.length} messages" }
      end
      if @messages.any?
        ol(class: 'event-list__items') do
          @messages.each_with_index do |msg, i|
            step = i + 1
            render MessageRow.new(
              message: msg,
              step: step,
              href: "/#{@campaign_id}/#{@donation_id}/#{step}",
              highlighted: step == @current_step
            )
          end
        end
      else
        p(class: 'event-list__empty') { 'No messages yet.' }
      end
    end
  end

  private

  def render_pagination
    prev_step = @current_step - 1
    next_step = @current_step + 1
    can_prev = prev_step >= 1
    can_next = next_step <= @messages.length

    span(class: 'event-list__pagination') do
      nav_link('←', prev_step, enabled: can_prev, title: 'Previous step')
      nav_link('→', next_step, enabled: can_next, title: 'Next step')
      span(class: 'event-list__seq') { "step: #{@current_step}" }
    end
  end

  def nav_link(label, step, enabled:, title:)
    classes = ['pager-button']
    if enabled
      a(class: classes.join(' '), href: "/#{@campaign_id}/#{@donation_id}/#{step}", title: title) { label }
    else
      classes << 'pager-button--disabled'
      span(class: classes.join(' '), title: title) { label }
    end
  end

  class MessageRow < Sidereal::Components::BaseComponent
    def initialize(message:, step:, href:, highlighted:)
      @message = message
      @step = step
      @href = href
      @highlighted = highlighted
    end

    def view_template
      is_command = @message.is_a?(Sourced::Command)
      classes = ['event-card', (is_command ? 'command' : 'event')]
      classes << 'highlighted' if @highlighted
      li(class: classes.join(' ')) do
        a(class: 'event-card__step', href: @href, title: "View state at step #{@step}") { @step.to_s }
        span(class: 'event-card__type') { @message.type }
        time(class: 'event-card__time', title: @message.created_at.iso8601, datetime: @message.created_at.iso8601) { @message.created_at.strftime('%H:%M:%S') }
      end
    end
  end
end
