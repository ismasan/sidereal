# frozen_string_literal: true

require 'securerandom'
require_relative 'piece'

class Square < Sidereal::Components::BaseComponent
  def initialize(coord:, piece:, friendly:, interactive:, game_id:)
    @coord = coord
    @piece = piece
    @friendly = friendly
    @interactive = interactive
    @game_id = game_id
  end

  def view_template
    if @interactive && @friendly
      render_source_button
    elsif @interactive
      render_target_form
    else
      render_static_cell
    end
  end

  private

  # Friendly cell on viewer's turn: a bare button that writes $from on click.
  # The selection ring follows reactively via data-class-selected.
  def render_source_button
    button(
      class: classes('square--friendly').join(' '),
      type: 'button',
      'aria-label': aria,
      'data-coord': @coord,
      data: {
        'on:click' => "$from = '#{@coord}'",
        'class-selected' => "$from === '#{@coord}'"
      }
    ) do
      render Piece.new(@piece) if @piece
    end
  end

  # Interactive non-friendly cell: a tiny MakeMove form.
  # Submit handler: copy $from into the hidden input imperatively
  # (data-attr-value didn't propagate to hidden inputs in Datastar
  # v1.0.1), then @post; finally reset $from. The if-guard short-circuits
  # when no source is selected so we don't fire empty submits.
  def render_target_form
    cid = "cmd#{SecureRandom.hex(3)}"
    submit_expr = <<~JS.gsub(/\s+/, ' ').strip
      if ($from) {
        el.querySelector('input[name="command[payload][from]"]').value = $from;
        @post('/commands', {contentType: 'form'});
        $from = '';
      }
    JS
    form(
      class: 'square-form',
      data: {
        'on:submit' => submit_expr
      }
    ) do
      input(type: 'hidden', name: 'command[type]', value: 'chess.make_move')
      input(type: 'hidden', name: 'command[_cid]', value: cid)
      input(type: 'hidden', name: 'command[payload][game_id]', value: @game_id)
      input(type: 'hidden', name: 'command[payload][to]', value: @coord)
      input(type: 'hidden', name: 'command[payload][from]', value: '')
      button(
        type: 'submit',
        class: classes.join(' '),
        'aria-label': aria,
        'data-coord': @coord
      ) do
        render Piece.new(@piece) if @piece
      end
    end
  end

  # Non-interactive cell: plain div, no handlers.
  def render_static_cell
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
