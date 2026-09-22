# frozen_string_literal: true

class ChatLayout < Sidereal::Components::Layout
  def view_template
    doctype

    html(lang: 'en') do
      head do
        meta(charset: 'utf-8')
        meta(name: 'viewport', content: 'width=device-width, initial-scale=1.0')
        title { 'Chat' }
        link(rel: 'stylesheet', href: '/css/main.css')
      end
      body do
        render page
      end
    end
  end
end
