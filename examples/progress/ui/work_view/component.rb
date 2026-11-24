# frozen_string_literal: true

# The progress ring: a <circular-progress> custom element, defined by the
# script next to this file. The component brings its script, and a small
# inline style, which the app registers when it installs it.
class WorkView < Sidereal::Components::BaseComponent
  javascript 'work_view.js', path: 'component.js'

  # Inline, registered as work_view-1.css
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
