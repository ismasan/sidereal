# frozen_string_literal: true

require_relative 'piece'

class Square < Sidereal::Components::BaseComponent
  def initialize(coord:, piece:, friendly:, interactive:,
                 is_selected:, is_valid_target:, selected_source_coord:, game_id:)
    @coord = coord
    @piece = piece
    @friendly = friendly
    @interactive = interactive
    @is_selected = is_selected
    @is_valid_target = is_valid_target
    @selected_source_coord = selected_source_coord
    @game_id = game_id
  end

  def view_template
    if @is_selected
      render_selected_source
    elsif @interactive && @friendly
      render_friendly
    elsif @interactive && @is_valid_target
      render_valid_target
    else
      render_static
    end
  end

  private

  # Currently-selected friendly piece. Re-submitting SelectSource with
  # the same coord toggles it off (handled server-side).
  def render_selected_source
    command SelectSource, class: 'square-form' do |f|
      f.payload_fields(game_id: @game_id, coord: @coord)
      button(
        type: :submit,
        class: classes('square--friendly', 'selected').join(' '),
        'aria-label': aria,
        'data-coord': @coord
      ) do
        render Piece.new(@piece) if @piece
      end
    end
  end

  # Friendly piece on viewer's turn but not currently selected. Clicking
  # selects it (or switches the source if another was already selected).
  def render_friendly
    command SelectSource, class: 'square-form' do |f|
      f.payload_fields(game_id: @game_id, coord: @coord)
      button(
        type: :submit,
        class: classes('square--friendly').join(' '),
        'aria-label': aria,
        'data-coord': @coord
      ) do
        render Piece.new(@piece) if @piece
      end
    end
  end

  # Legal destination from the currently-selected source. Submitting
  # MakeMove posts a fully-formed move (server-stamped from + to).
  def render_valid_target
    command Game::MakeMove, class: 'square-form' do |f|
      f.payload_fields(
        game_id: @game_id,
        from: @selected_source_coord.to_s,
        to: @coord
      )
      button(
        type: :submit,
        class: classes('square--valid-target').join(' '),
        'aria-label': aria,
        'data-coord': @coord
      ) do
        render Piece.new(@piece) if @piece
      end
    end
  end

  # No-op cell: spectator, opponent's turn, or an irrelevant square (no
  # selection or not a legal target). Rendered as a plain div with no
  # handlers so clicks do nothing.
  def render_static
    div(
      class: classes.join(' '),
      'aria-label': aria,
      'data-coord': @coord
    ) do
      render Piece.new(@piece) if @piece
    end
  end

  def classes(*extras)
    out = ['square', square_color]
    out << 'square--has-piece' if @piece
    out.concat(extras)
    out
  end

  def square_color
    file = @coord[0].ord - 'a'.ord
    rank = @coord[1].to_i - 1
    (file + rank).even? ? 'square--dark' : 'square--light'
  end

  def aria
    @piece ? "#{@coord} (#{Piece::NAMES.fetch(@piece, @piece)})" : @coord
  end
end
