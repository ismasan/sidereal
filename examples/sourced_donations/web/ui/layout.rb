# frozen_string_literal: true

module UI
  class Layout < Sidereal::Components::Layout
    def view_template
      doctype

      html do
        head do
          meta(charset: 'utf-8')
          meta(name: 'viewport', content: 'width=device-width, initial-scale=1.0')
          title { 'Donations Kiosk' }
        end
        body do
          div(class: 'page') do
            img(src: asset_url('img/logo.svg'), alt: 'Donations Kiosk', width: 48, height: 48)
            render page
          end
        end
      end
    end
  end
end
