# frozen_string_literal: true

module Sidereal
  module Components
    class BasicLayout < Layout
      STYLES = <<~CSS.strip
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

        body {
          font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
          line-height: 1.6;
          color: #1a1a1a;
          background: #f8f8f8;
          -webkit-font-smoothing: antialiased;
        }

        .page {
          max-width: 40rem;
          margin: 2rem auto;
          padding: 0 1.5rem;
        }

        h1, h2, h3 { line-height: 1.25; margin-bottom: 0.5em; }
        h1 { font-size: 1.75rem; }
        h2 { font-size: 1.35rem; }
        p  { margin-bottom: 1em; }

        a { color: #2563eb; text-decoration: none; }
        a:hover { text-decoration: underline; }

        ul, ol { padding-left: 1.25em; margin-bottom: 1em; }
        li { margin-bottom: 0.25em; }

        input[type="text"],
        input[type="email"],
        input[type="password"],
        input[type="number"],
        input[type="search"],
        textarea,
        select {
          display: block;
          width: 100%;
          padding: 0.5rem 0.65rem;
          font: inherit;
          font-size: 0.95rem;
          border: 1px solid #d0d0d0;
          border-radius: 6px;
          background: #fff;
          transition: border-color 0.15s;
        }
        input:focus, textarea:focus, select:focus {
          outline: none;
          border-color: #2563eb;
          box-shadow: 0 0 0 2px rgba(37,99,235,0.15);
        }

        button, input[type="submit"] {
          display: inline-flex;
          align-items: center;
          gap: 0.35em;
          padding: 0.5rem 1rem;
          font: inherit;
          font-size: 0.9rem;
          font-weight: 500;
          color: #fff;
          background: #2563eb;
          border: none;
          border-radius: 6px;
          cursor: pointer;
          transition: background 0.15s;
        }
        button:hover, input[type="submit"]:hover { background: #1d4ed8; }
        button:active, input[type="submit"]:active { background: #1e40af; }

        label {
          display: block;
          font-size: 0.85rem;
          font-weight: 500;
          margin-bottom: 0.25em;
          color: #444;
        }

        form > * + * { margin-top: 0.75rem; }

        table {
          width: 100%;
          border-collapse: collapse;
          margin-bottom: 1em;
        }
        th, td {
          text-align: left;
          padding: 0.5rem 0.75rem;
          border-bottom: 1px solid #e5e5e5;
        }
        th { font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.04em; color: #666; }

        .flash {
          padding: 0.75rem 1rem;
          border-radius: 6px;
          margin-bottom: 1rem;
          font-size: 0.9rem;
        }
        .flash--info    { background: #eff6ff; color: #1e40af; }
        .flash--success { background: #f0fdf4; color: #166534; }
        .flash--error   { background: #fef2f2; color: #991b1b; }

        .command-field { margin-bottom: 0.5rem; }
        .command-field.errors input,
        .command-field.errors textarea,
        .command-field.errors select {
          border-color: #dc2626;
        }
        .command-field.errors input:focus,
        .command-field.errors textarea:focus,
        .command-field.errors select:focus {
          box-shadow: 0 0 0 2px rgba(220,38,38,0.15);
        }
        .command-field__errors {
          display: block;
          font-size: 0.8rem;
          color: #dc2626;
          margin-top: 0.2em;
        }
      CSS

      def initialize(page)
        @page = page
      end

      def view_template
        doctype

        html do
          head do
            meta(name: 'viewport', content: 'width=device-width, initial-scale=1.0')
            title { 'basic' }
            sidereal_head
            style { STYLES }
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
  end
end
