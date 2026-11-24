# frozen_string_literal: true

require 'securerandom'

# The "Start new game" form, on the home page and at the end of a game. It
# handles the command it sends: ChessApp installs it with `component`.
class NewGameButton < Sidereal::Components::BaseComponent
  # Runs in the request: only a logged-in player can start a game, which
  # they play as White, and they're taken straight to it.
  handle Game::CreateGame do |cmd|
    halt 401, 'login required' if session[:username].to_s.empty?
    dispatch cmd
    browser.redirect "/games/#{cmd.payload.game_id}"
  end

  # @param form_class [String] the form's CSS class
  def initialize(form_class:)
    @form_class = form_class
  end

  def view_template
    command Game::CreateGame, class: @form_class do |f|
      f.payload_fields(game_id: SecureRandom.uuid)
      button(type: :submit, class: 'primary-button') { 'Start new game' }
    end
  end
end
