# frozen_string_literal: true

class ModeratorLayout < Sidereal::Components::Layout
  def view_template
    doctype

    html(lang: 'en') do
      head do
        meta(charset: 'utf-8')
        meta(name: 'viewport', content: 'width=device-width, initial-scale=1.0')
        title { 'Moderator' }
        link(rel: 'preconnect', href: 'https://fonts.googleapis.com')
        link(rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: true)
        link(rel: 'stylesheet', href: 'https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&display=swap')
        link(rel: 'stylesheet', href: "/css/main.css?a=#{Time.now.to_i}")
      end
      body do
        render page
      end
    end
  end
end
