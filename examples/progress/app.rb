# frozen_string_literal: true

require 'sidereal'
require 'async'

# -- Messages --

StartProgress = Sidereal::Message.define('progress.start')

ProgressStarted = Sidereal::Message.define('progress.started')

ProgressTicked = Sidereal::Message.define('progress.ticked') do
  attribute :percent, Integer
end

ActivityLogged = Sidereal::Message.define('progress.activity_logged') do
  attribute :message, Sidereal::Types::String
end

ProgressCompleted = Sidereal::Message.define('progress.completed')

require_relative 'ui/layout'
require_relative 'ui/progress_page'

# -- App --
class ProgressApp < Sidereal::App
  session secret: 'c' * 64

  layout Layout

  # Expose StartProgress to the web; the default handler appends it to the
  # store so a worker fiber picks it up and runs `command StartProgress`.
  handle StartProgress

  command StartProgress do |cmd|
    broadcast ProgressStarted

    # Activity log: a sibling fiber broadcasting at a slow cadence.
    Async do
      ['Work started', 'Connecting to API', 'downloading data', 'processing data'].each do |msg|
        broadcast ActivityLogged, message: msg
        sleep rand(0.5..1.7)
      end
    end

    # Progress ticks: broadcast signal updates at a fast cadence.
    0.upto(100) do |i|
      sleep rand(0.03..0.09)
      broadcast ProgressTicked, percent: i
    end

    broadcast ProgressCompleted
  end

  page ProgressPage
end
