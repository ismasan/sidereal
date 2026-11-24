# frozen_string_literal: true

require_relative 'ui/layout'
require_relative 'ui/home_page'
require_relative 'ui/game_page'

class ChessApp < Sidereal::App
  # Scoped cookie name so this demo's session doesn't collide with the
  # other examples on localhost. The key is derived from the app's secret,
  # SIDEREAL_SECRET or storage/secret.txt.
  session secret: -> { Sidereal.secrets.derive('session') }, key: 'sidereal_chess.session'
  layout ChessLayout

  # public/: stylesheets, scripts and images, served with digests in
  # their URLs. The layout links the stylesheets and scripts.
  assets.directory Sidereal.root.join('public')

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
        game_id: id,
        state: state,
        messages: messages,
        viewer_username: session[:username],
        current_step: step_int
      )
    )
  end

  # Components that handle the commands their forms send: CreateGame,
  # SelectSource and MakeMove, and JoinGame. Each declares its handlers next
  # to its form; installing it here exposes them. GamePage handles Resign,
  # and `page` installs that too.
  component NewGameButton
  component Square
  component SeatPanel

  # Square, SeatPanel and StatusBanner declare their own stylesheets, which
  # installing them registers. StatusBanner handles no commands: it's
  # installed only for its styles. The rest of the app's styles are in
  # public/css/main.css.
  component StatusBanner

  page HomePage
  page GamePage
end
