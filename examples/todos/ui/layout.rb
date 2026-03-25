# frozen_string_literal: true

class Layout < Sidereal::Layout
  def initialize(page)
    @page = page
  end

  def view_template
    doctype

    html do
      head do
        meta(name: 'viewport', content: 'width=device-width, initial-scale=1.0')
        title { 'Todos' }
        link(rel: 'stylesheet', href: '/css/main.css')
        sidereal_head
      end
      body do
        div(class: 'page') do
          render @page
        end

        sidereal_foot
      end
    end
  end
end
