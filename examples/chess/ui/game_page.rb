# frozen_string_literal: true

require_relative 'components/board'
require_relative 'components/move_list'
require_relative 'components/event_list'
require_relative 'components/score'
require_relative 'components/status_banner'
require_relative 'components/seat_panel'

class GamePage < Sidereal::Page
  path '/games/:id'

  on Game::PlayerJoined,
     Game::MoveMade,
     Game::GameEnded do |_evt|
    browser.patch_elements GamePage.load(params, context)
  end

  def self.load(params, ctx, selected_source: nil, current_step: nil)
    state, messages = load_state_with_history(params[:id], upto: current_step)
    new(
      state: state,
      messages: messages,
      viewer_username: ctx.session[:username],
      selected_source: selected_source,
      current_step: current_step
    )
  end

  # Reads all messages for a game, replays them through GameView. With
  # +upto+, only the first N messages contribute to the projected state —
  # the full message list is still returned for the sidebar.
  def self.load_state_with_history(game_id, upto: nil)
    result = Sourced.store.read_partition(
      { game_id: game_id },
      handled_types: Game.handled_messages_for_evolve.map(&:type)
    )
    messages = result.messages

    if upto
      view = GameView.new({ game_id: game_id })
      view.evolve(messages.first(upto))
      [view.state, messages]
    else
      view, _ = Sourced.load(GameView, game_id: game_id)
      [view.state, messages]
    end
  end

  def initialize(state:, messages:, viewer_username:, selected_source: nil, current_step: nil)
    @state = state
    @messages = messages
    @viewer = viewer_username.to_s
    @selected_source = selected_source
    @current_step = current_step
  end

  # Historic snapshots use a static channel so live SSE events don't
  # override the frozen view.
  def channel_name = @current_step ? 'static' : "games.#{@state.game_id}"

  # Suppress page_key on historic snapshots so Page.subscribe early-returns
  # and doesn't re-render the page from current state on SSE connect.
  def page_signals = @current_step ? {} : super

  def viewer_color
    return 'white' if @state.white_username && @viewer == @state.white_username
    return 'black' if @state.black_username && @viewer == @state.black_username
    'spectator'
  end

  def side_to_move
    return nil unless @state.fen
    @state.fen.split(' ')[1] == 'w' ? 'white' : 'black'
  end

  def historic? = !!@current_step

  def your_turn?
    return false if historic?
    return false unless @state.status == 'in_progress'
    side_to_move == viewer_color
  end

  def view_template
    div(id: 'game-page') do
      header(class: 'header') do
        h1 do
          a(href: '/') { 'Sidereal Chess' }
        end
        if !@viewer.empty?
          div(class: 'session') do
            span(class: 'session__name') { "Signed in as #{@viewer}" }
          end
        end
      end

      if historic?
        div(class: 'historic-banner') do
          plain "Viewing step #{@current_step} of #{@messages.length} — "
          a(href: "/games/#{@state.game_id}") { 'back to live' }
        end
      end

      div(class: 'game-layout') do
        div(class: 'game-layout__main') do
          unless historic?
            render StatusBanner.new(
              state: @state,
              viewer_color: viewer_color,
              side_to_move: side_to_move,
              your_turn: your_turn?
            )
            render SeatPanel.new(
              state: @state,
              viewer_color: viewer_color,
              viewer_username: @viewer
            )
          end
          if @state.fen
            render Board.new(
              fen: @state.fen,
              viewer_color: viewer_color,
              interactive: your_turn?,
              game_id: @state.game_id,
              selected_source: @selected_source
            )
          end
        end

        aside(class: 'sidebar') do
          render Score.new(@state.captured)
          render MoveList.new(move_messages)
          render EventList.new(
            messages: @messages,
            game_id: @state.game_id,
            current_step: @current_step
          )
          render_actions unless historic?
        end
      end
    end
  end

  private

  def move_messages
    @messages.select { |m| m.type == Game::MoveMade.type }
  end

  def render_actions
    section(class: 'sidebar__section') do
      if @state.status == 'in_progress' && %w[white black].include?(viewer_color)
        command Game::Resign, class: 'inline-form' do |f|
          f.payload_fields(game_id: @state.game_id)
          button(type: :submit, class: 'secondary-button') { 'Resign' }
        end
      end

      if @state.status == 'ended' && !@viewer.empty?
        command Game::CreateGame, class: 'inline-form' do |f|
          f.payload_fields(game_id: SecureRandom.uuid)
          button(type: :submit, class: 'primary-button') { 'Start new game' }
        end
      end
    end
  end
end
