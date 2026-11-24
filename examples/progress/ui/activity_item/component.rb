# frozen_string_literal: true

# One line of the activity log. Its stylesheet is the file next to this one,
# registered with the app as activity_item.css when the app installs it.
class ActivityItem < Sidereal::Components::BaseComponent
  stylesheet 'activity_item.css', path: 'component.css'

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
