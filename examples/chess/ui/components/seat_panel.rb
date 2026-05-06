# frozen_string_literal: true

class SeatPanel < Sidereal::Components::BaseComponent
  def initialize(state:, viewer_color:, viewer_username:)
    @state = state
    @viewer = viewer_color
    @username = viewer_username
  end

  def view_template
    div(id: 'seat-panel', class: 'seat-panel') do
      div(class: 'seat-panel__seat seat-panel__seat--white') do
        span(class: 'seat-panel__chip seat-panel__chip--white') { '♔' }
        strong { @state.white_username || '—' }
        span(class: 'seat-panel__role') { 'White' }
      end

      div(class: 'seat-panel__seat seat-panel__seat--black') do
        span(class: 'seat-panel__chip seat-panel__chip--black') { '♚' }
        if @state.black_username
          strong { @state.black_username }
          span(class: 'seat-panel__role') { 'Black' }
        elsif can_sit?
          command Game::JoinGame, class: 'inline-form' do |f|
            f.payload_fields(game_id: @state.game_id)
            button(type: :submit, class: 'primary-button') { 'Sit as black' }
          end
        else
          span(class: 'seat-panel__role muted') { 'Awaiting black…' }
        end
      end
    end
  end

  private

  # Only an unseated logged-in user who isn't already white can claim black.
  def can_sit?
    return false if @username.to_s.empty?
    return false if @username == @state.white_username
    @state.black_username.nil?
  end
end
