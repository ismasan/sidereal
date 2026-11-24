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

  # The progress ring: a <circular-progress> custom element, defined by the
  # script next to this file. The component brings its own script and style,
  # which the app registers with `install ProgressPage::WorkView`.
  class WorkView < Sidereal::Components::BaseComponent
    javascript 'circular-progress.js', path: 'circular-progress.js'

    # Registered as progress_page/work_view-1.css
    css <<~CSS
      #title {
        text-align: center;
      }
    CSS

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

  # One line of the activity log, with its own inline stylesheet, registered
  # as progress_page/activity_item-1.css.
  class ActivityItem < Sidereal::Components::BaseComponent
    css <<~CSS
      .a-item {
        background: white;
        border: 1px solid #e8e8e8;
        border-radius: 6px;
        padding: 12px 16px;
        margin-bottom: 8px;
        font-size: 14px;
        color: #333;
        box-shadow: 0 1px 2px rgba(0,0,0,0.05);
        transition: all 0.2s ease;
      }
      .a-item:last-child {
        margin-bottom: 0;
      }
      .a-item:hover {
        background: #f8f9fa;
        border-color: #d0d0d0;
      }
      .a-item .time {
        display: block;
        font-size: 11px;
        color: #888;
        margin-bottom: 4px;
        font-family: monospace;
      }
      .a-item.done {
        background: #f0f9f4;
        border-color: #6bdba7;
        color: #2d5a3d;
      }
      .a-item.done .time {
        color: #5a8a6a;
      }
    CSS

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
