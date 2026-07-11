# frozen_string_literal: true

require 'securerandom'
require_relative 'components/games_list'

class HomePage < Sidereal::Page
  path '/'

  # Re-render the lobby whenever any game projector commits — that's the
  # synthetic Projected signal the GamesProjector auto-publishes after each upsert.
  on GamesProjector::Projected do |_evt|
    browser.patch_elements load(params)
  end

  def self.load(_params, ctx)
    username = ctx.session[:username]
    new(
      username: username,
      open_games: GamesProjector.open_games,
      your_games: username ? GamesProjector.games_for(username) : []
    )
  end

  def initialize(username: nil, open_games: [], your_games: [])
    @username = username
    @open_games = open_games
    @your_games = your_games
  end

  # Glob subscription: catches every game's events (per-game channels are
  # named `games.<id>`) plus the synthetic Projected signal. Sidereal page
  # reactions only fire on declared `on` events, so the glob is safe.
  def channel_name = 'games.>'

  def view_template
    div(id: 'home-page') do
      header(class: 'header') do
        h1 { 'Sidereal Chess' }
        if @username
          div(class: 'session') do
            span(class: 'session__name') { "Signed in as #{@username}" }
            form(action: '/logout', method: 'post', class: 'inline-form') do
              button(type: :submit, class: 'link-button') { 'Sign out' }
            end
          end
        end
      end

      main(class: 'lobby') do
        section(class: 'panel') do
          if @username.to_s.empty?
            render LoginForm.new
          else
            render NewGameForm.new(@username)
          end
        end

        section(class: 'panel') do
          h2 { 'Open games' }
          render GamesList.new(@open_games, viewer_username: @username, kind: :open)
        end

        unless @username.to_s.empty?
          section(class: 'panel') do
            h2 { 'Your games' }
            render GamesList.new(@your_games, viewer_username: @username, kind: :yours)
          end
        end
      end
    end
  end

  class LoginForm < Sidereal::Components::BaseComponent
    def view_template
      h2 { 'Pick a name' }
      p(class: 'lede') { 'Your name is stored in the browser session — used to label the players in any game you start or join.' }

      form(action: '/login', method: 'post', class: 'login-form', autocomplete: 'off') do
        input(type: 'text', name: 'login[username]', placeholder: 'e.g. Alice', autofocus: true, required: true)
        button(type: :submit, class: 'primary-button') { 'Continue' }
      end
    end
  end

  class NewGameForm < Sidereal::Components::BaseComponent
    def initialize(username)
      @username = username
    end

    def view_template
      h2 { "Hello, #{@username}" }
      p(class: 'lede') { 'Start a new game and share the URL with your opponent. You play White.' }

      command Game::CreateGame, class: 'new-game-form' do |f|
        f.payload_fields(game_id: SecureRandom.uuid)
        button(type: :submit, class: 'primary-button') { 'Start new game' }
      end
    end
  end
end
