# frozen_string_literal: true

module UI
  # Page layout: Sidereal's BasicLayout styles, plus this app's own stylesheet
  # in web/public/css/app.css.
  class Layout < Sidereal::Components::BasicLayout
    FONTS = 'https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:ital,wght@0,400;0,700;1,400&family=Unbounded:wght@500;700&display=swap'
    NOW = Time.now.to_s

    def view_template
      doctype

      html(lang: 'en') do
        head do
          meta(charset: 'utf-8')
          meta(name: 'viewport', content: 'width=device-width, initial-scale=1.0')
          title { 'Machine' }
          link(rel: 'preconnect', href: 'https://fonts.googleapis.com')
          link(rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: true)
          link(rel: 'stylesheet', href: FONTS)
          style { raw safe(STYLES) }
          link(rel: 'stylesheet', href: "/css/app.css?a=#{NOW}")
          # Step links patch the page and push its URL: going back or forward
          # loads the page at the URL the browser lands on.
          script { raw safe("addEventListener('popstate', () => location.reload())") }
        end

        body do
          div(class: 'page') do
            render page
          end
        end
      end
    end
  end
end
