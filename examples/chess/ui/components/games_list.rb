# frozen_string_literal: true

# Renders one of the two lobby sections — open games or "Your games".
# Each row is a link to /games/<id>; joining still happens on the GamePage.
class GamesList < Sidereal::Components::BaseComponent
  def initialize(games, viewer_username:, kind:)
    @games = games
    @viewer = viewer_username.to_s
    @kind = kind
  end

  def view_template
    if @games.empty?
      p(class: 'games-list__empty') { empty_message }
    else
      ul(class: 'games-list') do
        @games.each { |g| render Row.new(game: g, viewer_username: @viewer, kind: @kind) }
      end
    end
  end

  private

  def empty_message
    case @kind
    when :open  then 'No open games yet.'
    when :yours then "You haven't joined any games yet."
    end
  end

  class Row < Sidereal::Components::BaseComponent
    def initialize(game:, viewer_username:, kind:)
      @g = game
      @viewer = viewer_username
      @kind = kind
    end

    def view_template
      li(class: "games-list__item games-list__item--#{@g[:status]}") do
        a(href: "/games/#{@g[:game_id]}", class: 'games-list__link') do
          if @kind == :open
            render_open_row
          else
            render_yours_row
          end
        end
      end
    end

    private

    def render_open_row
      span(class: 'games-list__title') do
        plain "#{@g[:white_username]}'s game"
      end
      span(class: 'games-list__meta') do
        plain 'waiting for Black'
        plain ' · your game' if @viewer == @g[:white_username]
      end
    end

    def render_yours_row
      viewer_color = @viewer == @g[:white_username] ? 'White' : 'Black'
      opponent = viewer_color == 'White' ? @g[:black_username] : @g[:white_username]

      span(class: "games-list__pill games-list__pill--#{viewer_color.downcase}") { viewer_color }
      span(class: 'games-list__title') do
        plain "vs #{opponent || '—'}"
      end
      span(class: 'games-list__meta') { yours_meta(viewer_color) }
    end

    def yours_meta(viewer_color)
      case @g[:status]
      when 'in_progress'
        "move #{@g[:move_count]}"
      when 'ended'
        result_label(viewer_color)
      else
        @g[:status]
      end
    end

    def result_label(viewer_color)
      winner = @g[:winner]
      if winner.nil?
        'draw'
      elsif winner == viewer_color.downcase
        @g[:end_reason] == 'resignation' ? 'opponent resigned' : 'you won'
      else
        @g[:end_reason] == 'resignation' ? 'you resigned' : 'you lost'
      end
    end
  end
end
