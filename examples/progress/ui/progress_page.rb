# frozen_string_literal: true

class ProgressPage < Sidereal::Page
  path '/'

  # Pre-declare so $progress exists before the first tick arrives.
  def page_signals
    super.merge(progress: 0)
  end

  # Reactions — run for every tab subscribed to the 'system' channel.

  on ProgressStarted do |_evt|
    browser.patch_elements WorkView.new
    browser.patch_elements %(<div id="activity" class="col"></div>)
    browser.patch_signals(progress: 0)
  end

  on ProgressTicked do |evt|
    browser.patch_signals(progress: evt.payload.percent)
  end

  on ActivityLogged do |evt|
    browser.patch_elements(
      ActivityItem.new(evt.payload.message, evt.created_at),
      mode: 'append', selector: '#activity'
    )
  end

  on ProgressCompleted do |evt|
    browser.patch_elements %(<h1 id="title">Done!</h1>)
    browser.patch_elements(
      ActivityItem.new('Done!', evt.created_at, done: true),
      mode: 'append', selector: '#activity'
    )
  end

  def self.load(_params, _ctx)
    new
  end

  class WorkView < Sidereal::Components::BaseComponent
    register_element :circular_progress

    def view_template
      circular_progress(
        id: 'work',
        data: { 'bind:progress' => true, 'attr:progress' => '$progress' }
      ) do
        h1(id: 'title') { 'Processing...' }
      end
    end
  end

  class ActivityItem < Sidereal::Components::BaseComponent
    def initialize(message, created_at, done: false)
      @message = message
      @created_at = created_at
      @done = done
    end

    def view_template
      div(class: @done ? 'a-item done' : 'a-item') do
        span(class: 'time') { @created_at.iso8601 }
        plain @message
      end
    end
  end

  def view_template
    div(class: 'demo-container') do
      div(class: 'col') do
        command StartProgress, class: 'start-form' do |_f|
          button(type: :submit) { 'Start' }
        end
        div(id: 'work')
      end

      div(class: 'col', id: 'activity')
    end
  end
end
