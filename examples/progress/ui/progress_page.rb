# frozen_string_literal: true

require_relative 'work_view/component'
require_relative 'activity_item/component'

class ProgressPage < Sidereal::Page
  path '/'

  # The page handles each of its events itself, below. Without this, the Start
  # form would also have it reload when StartProgress comes back over pubsub,
  # once the handler finishes, putting the Start button back over "Done!".
  disable_causal_reactivity!

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

  # The root has an id: the page's stream patches the whole page in when it
  # connects, and Datastar matches the patch by it.
  def view_template
    div(id: 'progress-page', class: 'demo-container') do
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
