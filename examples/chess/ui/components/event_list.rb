# frozen_string_literal: true

# Chronological history of all messages for a game, with each row
# linking to a frozen-snapshot URL that replays state up to that step.
# Mirrors the donations EventList but renders chess-specific labels.
class EventList < Sidereal::Components::BaseComponent
  def initialize(messages:, game_id:, current_step: nil)
    @messages = messages
    @game_id = game_id
    @current_step = current_step || messages.length
  end

  def view_template
    section(id: 'event-list', class: 'sidebar__section') do
      header(class: 'event-list__header') do
        h3 { 'History' }
        render_pagination if @messages.any?
      end
      if @messages.any?
        ol(class: 'event-list__items') do
          @messages.each_with_index do |msg, i|
            step = i + 1
            render MessageRow.new(
              message: msg,
              step: step,
              href: "/games/#{@game_id}/#{step}",
              highlighted: step == @current_step
            )
          end
        end
      else
        p(class: 'event-list__empty') { 'No events yet.' }
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
      span(class: 'event-list__seq') { "step: #{@current_step}" }
      nav_link('→', next_step, enabled: can_next, title: 'Next step')
      a(class: 'event-list__live', href: "/games/#{@game_id}", title: 'Back to live') { 'live' }
    end
  end

  def nav_link(label, step, enabled:, title:)
    classes = ['pager-button']
    if enabled
      a(class: classes.join(' '), href: "/games/#{@game_id}/#{step}", title: title) { label }
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
      classes = ['event-card']
      classes << 'highlighted' if @highlighted
      li(class: classes.join(' ')) do
        a(class: 'event-card__step', href: @href, title: "View state at step #{@step}") { @step.to_s }
        span(class: 'event-card__type') { label_for(@message) }
        time(
          class: 'event-card__time',
          title: @message.created_at.iso8601,
          datetime: @message.created_at.iso8601
        ) { @message.created_at.strftime('%H:%M:%S') }
      end
    end

    private

    def label_for(msg)
      case msg.type
      when Game::GameCreated.type
        "Game started — #{msg.payload.white_username} (white)"
      when Game::PlayerJoined.type
        "#{msg.payload.username} joined as #{msg.payload.color}"
      when Game::MoveMade.type
        "#{msg.payload.color} #{annotated_san(msg)}"
      when Game::GameEnded.type
        ended_label(msg)
      else
        msg.type
      end
    end

    def annotated_san(msg)
      san = msg.payload.san.to_s
      san += '#' if msg.payload.checkmate
      san += '+' if msg.payload.check && !msg.payload.checkmate && !san.end_with?('+')
      san
    end

    def ended_label(msg)
      reason = msg.payload.reason
      winner = msg.payload.winner
      case reason
      when 'checkmate'    then "Checkmate — #{winner} wins"
      when 'stalemate'    then 'Stalemate — draw'
      when 'resignation'  then "#{winner} wins by resignation"
      else "Game ended (#{reason})"
      end
    end
  end
end
