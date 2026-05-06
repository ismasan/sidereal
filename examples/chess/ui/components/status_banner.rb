# frozen_string_literal: true

class StatusBanner < Sidereal::Components::BaseComponent
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
