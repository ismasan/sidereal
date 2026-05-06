# frozen_string_literal: true

require_relative 'ui/layout'
require_relative 'ui/home_page'
require_relative 'ui/game_page'

class ChessApp < Sidereal::App
  # Scoped cookie name so this demo's session doesn't collide with the
  # other examples on localhost (each app uses a different secret).
  session secret: 'c' * 64, key: 'sidereal_chess.session'
  layout ChessLayout

  # Stamps the session username onto every command. Each command declares
  # which field it actually accepts (`username` or `white_username`);
  # Plumb's payload validation drops anything unknown.
  before_command do |cmd|
    name = session[:username].to_s
    cmd
      .with_metadata(producer: 'UI')
      .with_payload(username: name, white_username: name)
  end

  # Channel naming: per-game channel for game events; bare 'games' for
  # everything else (currently nothing else publishes here).
  channel_name do |msg|
    if msg.payload.respond_to?(:game_id) && msg.payload.game_id
      "games.#{msg.payload.game_id}"
    else
      'games'
    end
  end

  # ---- Session management ----
  # Plain HTML form posts (not Sourced commands) so they bypass
  # `before_command` and avoid coupling no-payload session writes to the
  # command-validation pipeline.

  post '/login' do
    username = request.params.dig('login', 'username').to_s.strip
    if username.empty?
      session[:username] = nil
      redirect '/'
    else
      session[:username] = username
      redirect '/'
    end
  end

  post '/logout' do
    session.clear
    redirect '/'
  end

  # ---- Game lifecycle ----

  handle Game::CreateGame do |cmd|
    halt 401, 'login required' if session[:username].to_s.empty?
    dispatch cmd
    browser.redirect "/games/#{cmd.payload.game_id}"
  end

  handle Game::JoinGame
  handle Game::MakeMove
  handle Game::Resign

  page HomePage
  page GamePage
end
