# frozen_string_literal: true

require_relative 'ui/layout'
require_relative 'ui/home_page'
require_relative 'ui/game_page'

# UI-only message: clicking a friendly piece submits this to mutate
# per-session selection state and trigger a server-side board re-render
# via SSE. NOT a Sourced::Command — it never reaches the event store.
SelectSource = Sidereal::Message.define('chess.select_source') do
  attribute :game_id, Sidereal::Types::UUID::V4
  attribute :coord,   Sidereal::Types::String.present
end

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

  # Frozen-snapshot view: renders GamePage with state replayed up to the
  # Nth message of this game's stream. Static — no SSE subscription.
  # Step links in the EventList sidebar point here.
  get '/games/:id/:step' do |id:, step:|
    step_int = Integer(step, 10) rescue nil
    halt 404, 'Not found' unless step_int && step_int > 0

    state, messages = GamePage.load_state_with_history(id, upto: step_int)
    halt 404, 'Not found' if messages.length < step_int

    component self.class.layout.new(
      GamePage.new(
        state: state,
        messages: messages,
        viewer_username: session[:username],
        current_step: step_int
      )
    )
  end

  handle Game::CreateGame do |cmd|
    halt 401, 'login required' if session[:username].to_s.empty?
    dispatch cmd
    browser.redirect "/games/#{cmd.payload.game_id}"
  end

  handle Game::JoinGame
  handle Game::MakeMove
  handle Game::Resign

  # SelectSource is processed inline (NOT dispatched). It carries the
  # selected cell coord; the re-rendered GamePage uses it to highlight
  # the source and show valid destinations. No persistence — the next
  # SSE re-render (e.g., after MoveMade) drops the selection naturally.
  # Synthesize `{ id: ... }` for GamePage.load because POST /commands
  # has no :id segment in the URL.
  handle SelectSource do |cmd|
    browser.patch_elements GamePage.load(
      { id: cmd.payload.game_id },
      self,
      selected_source: cmd.payload.coord
    )
  end

  page HomePage
  page GamePage
end
