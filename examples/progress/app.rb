# frozen_string_literal: true

require 'sidereal'

# -- Messages --

StartProgress = Sidereal::Message.define('progress.start')

require_relative 'ui/layout'
require_relative 'ui/progress_page'

# -- App --
class ProgressApp < Sidereal::App
  session secret: 'c' * 64

  layout Layout

  handle StartProgress do |cmd|
    # Progress stream: mount <circular-progress>, then tick the signal 0 -> 100.
    browser.stream do |sse|
      sse.patch_elements ProgressPage::WorkView.new
      0.upto(100) do |i|
        sleep rand(0.03..0.09)
        sse.patch_signals(progress: i)
      end
      sse.patch_elements %(<h1 id="title">Done!</h1>)
      sse.patch_elements ProgressPage::ActivityItem.new('Done!', Time.now, done: true),
                         mode: 'append', selector: '#activity'
    end

    # Activity stream: reset #activity, then append log items at slow cadence.
    browser.stream do |sse|
      sse.patch_elements %(<div id="activity" class="col"></div>)
      ['Work started', 'Connecting to API', 'downloading data', 'processing data'].each do |msg|
        sse.patch_elements(
          ProgressPage::ActivityItem.new(msg, Time.now), 
          mode: 'append', selector: '#activity'
        )

        sleep rand(0.5..1.7)
      end
    end
  end

  page ProgressPage
end
