# frozen_string_literal: true

require 'securerandom'

class HomePage < Sidereal::Page
  path '/'

  def self.load(_params, ctx)
    new(username: ctx.session[:username])
  end

  def initialize(username: nil)
    @username = username
  end

  # No live updates on the home page.
  def channel_name = 'static'

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

      main(class: 'panel') do
        if @username.to_s.empty?
          render LoginForm.new
        else
          render NewGameForm.new(@username)
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
      p(class: 'lede') { 'Start a new game and share the URL with your opponent. You play white.' }

      command Game::CreateGame, class: 'new-game-form' do |f|
        f.payload_fields(game_id: SecureRandom.uuid)
        button(type: :submit, class: 'primary-button') { 'Start new game' }
      end
    end
  end
end
