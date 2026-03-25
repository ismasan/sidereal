# frozen_string_literal: true

class ChatLayout < Sidereal::Components::Layout
  def view_template
    doctype

    html do
      head do
        meta(name: 'viewport', content: 'width=device-width, initial-scale=1.0')
        title { 'Chat' }
        link(rel: 'stylesheet', href: '/css/main.css')
        sidereal_head
      end
      body(data: sidereal_signals) do
        div(class: 'page') do
          render page
        end

        sidereal_foot
      end
    end
  end
end
