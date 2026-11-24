# frozen_string_literal: true

class StatusBanner < Sidereal::Components::BaseComponent
  # Its styles, inline: the app registers them as status_banner-1.css when it
  # installs the component.
  css <<~CSS
    .status-banner {
      padding: 14px 18px;
      border-radius: 10px;
      font-weight: 600;
      display: flex;
      justify-content: space-between;
      align-items: center;
      background: var(--panel);
      box-shadow: var(--shadow);
    }
    .status-banner--your-turn { background: var(--soft); color: var(--accent-strong); }
    .status-banner--waiting   { background: var(--panel); color: var(--muted); }
    .status-banner--ended     { background: #fff4e0; color: var(--warning); }

    .status-banner__chip {
      background: var(--danger);
      color: white;
      font-size: 12px;
      padding: 2px 8px;
      border-radius: 999px;
      text-transform: uppercase;
      letter-spacing: 0.4px;
    }
  CSS

  def initialize(state:, viewer_color:, side_to_move:, your_turn:)
    @state = state
    @viewer = viewer_color
    @side = side_to_move
    @your_turn = your_turn
  end

  def view_template
    text, modifier = label
    div(id: 'status-banner', class: "status-banner status-banner--#{modifier}") do
      strong { text }
      if @state.check && @state.status == 'in_progress'
        span(class: 'status-banner__chip') { 'check' }
      end
    end
  end

  private

  def label
    case @state.status
    when nil
      ['Game not found', 'ended']
    when 'created'
      ['Waiting for an opponent…', 'waiting']
    when 'ended'
      [ended_label, 'ended']
    when 'in_progress'
      in_progress_label
    end
  end

  def in_progress_label
    if @viewer == 'spectator'
      ["Spectating — #{@side} to move", 'waiting']
    elsif @your_turn
      ['Your turn', 'your-turn']
    else
      ['Opponent to move', 'waiting']
    end
  end

  def ended_label
    case @state.end_reason
    when 'checkmate'
      "Checkmate — #{@state.winner} wins"
    when 'stalemate'
      'Stalemate — draw'
    when 'resignation'
      "#{@state.winner.capitalize} wins by resignation"
    else
      'Game over'
    end
  end
end
