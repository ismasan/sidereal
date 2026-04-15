# frozen_string_literal: true

class DonationsLayout < Sidereal::Components::Layout
  def view_template
    doctype

    html do
      head do
        meta(name: 'viewport', content: 'width=device-width, initial-scale=1.0')
        title { 'Donations Kiosk' }
        link(rel: 'stylesheet', href: '/css/main.css')
      end
      body do
        div(class: 'page') do
          render page
        end
      end
    end
  end
end
