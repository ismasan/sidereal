# frozen_string_literal: true

require 'phlex'
require 'rbconfig'
require 'securerandom'

module Sidereal
  module Components
    # A development error report: the exception's class and message, the
    # source around the line that raised it, its backtrace with the app's
    # frames first, its causes, and the request.
    #
    # Rendered as a whole page for a page request, or as an overlay appended
    # to the page's +<body>+ for a Datastar request or a stream that raised.
    # See {Sidereal::ShowExceptions}.
    class ExceptionView < Phlex::HTML
      Frame = Data.define(:line, :path, :lineno, :app) do
        def self.parse(line, app_root)
          path, lineno = line.match(/\A(.+?):(\d+)(?::in |\z)/)&.captures
          app = !path.nil? && path.start_with?(app_root) && LIBRARY_PATHS.none? { |lib| path.start_with?(lib) }
          new(line:, path:, lineno: lineno&.to_i, app:)
        end

        def source? = app && File.file?(path)
      end

      LIBRARY_PATHS = [*Gem.path, RbConfig::CONFIG['rubylibdir']].compact.map { |path| File.join(File.expand_path(path), '') }.freeze
      SOURCE_CONTEXT = 5

      STYLES = <<~CSS
        .sidereal-exception { --sx-bg: #fff; --sx-fg: #1d1d1f; --sx-muted: #6e6e73; --sx-line: #e5e5ea;
          --sx-accent: #c4161c; --sx-code: #f5f5f7; --sx-hl: #fde7e7;
          box-sizing: border-box; font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          color: var(--sx-fg); background: var(--sx-bg); text-align: left; }
        @media (prefers-color-scheme: dark) {
          .sidereal-exception { --sx-bg: #1c1c1e; --sx-fg: #f2f2f7; --sx-muted: #98989d; --sx-line: #38383a;
            --sx-accent: #ff6961; --sx-code: #2c2c2e; --sx-hl: #4a2224; }
        }
        .sidereal-exception--overlay { position: fixed; inset: 0; z-index: 2147483647; overflow: auto;
          box-shadow: 0 0 0 100vmax rgb(0 0 0 / .4); }
        .sidereal-exception *, .sidereal-exception *::before, .sidereal-exception *::after { box-sizing: inherit; }
        .sidereal-exception__inner { max-width: 1100px; margin: 0 auto; padding: 24px 16px 48px; }
        .sidereal-exception__bar { display: flex; justify-content: space-between; align-items: center; gap: 16px;
          color: var(--sx-muted); font-size: 12px; text-transform: uppercase; letter-spacing: .06em; }
        .sidereal-exception__close { font: inherit; text-transform: none; letter-spacing: 0; cursor: pointer;
          color: var(--sx-fg); background: var(--sx-code); border: 1px solid var(--sx-line); border-radius: 6px; padding: 4px 10px; }
        .sidereal-exception h1 { margin: 8px 0 4px; font-size: 22px; color: var(--sx-accent); overflow-wrap: anywhere; }
        .sidereal-exception h2 { margin: 28px 0 8px; font-size: 13px; color: var(--sx-muted);
          text-transform: uppercase; letter-spacing: .06em; }
        .sidereal-exception pre, .sidereal-exception code { font: 12.5px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; }
        .sidereal-exception__message { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font-size: 14px; }
        .sidereal-exception__source { margin: 0; padding: 8px 0; background: var(--sx-code); border-radius: 8px; overflow-x: auto; }
        .sidereal-exception__source-file { margin: 0 0 6px; color: var(--sx-muted); overflow-wrap: anywhere; }
        .sidereal-exception__source span { display: block; padding: 0 12px; white-space: pre; }
        .sidereal-exception__source span.is-current { background: var(--sx-hl); }
        .sidereal-exception__source b { display: inline-block; min-width: 4ch; margin-right: 12px;
          color: var(--sx-muted); font-weight: normal; text-align: right; user-select: none; }
        .sidereal-exception__frames { margin: 0; padding: 0; list-style: none; border-top: 1px solid var(--sx-line); }
        .sidereal-exception__frames li { padding: 4px 0; border-bottom: 1px solid var(--sx-line);
          overflow-wrap: anywhere; color: var(--sx-muted); }
        .sidereal-exception__frames li.is-app { color: var(--sx-fg); }
        .sidereal-exception details summary { cursor: pointer; color: var(--sx-muted); margin: 12px 0 6px; }
        .sidereal-exception dl { display: grid; grid-template-columns: max-content 1fr; gap: 4px 16px; margin: 0; }
        .sidereal-exception dt { color: var(--sx-muted); }
        .sidereal-exception dd { margin: 0; overflow-wrap: anywhere; }
      CSS

      # @param exception [Exception]
      # @param request [Rack::Request, nil] the request that raised, if any
      # @param overlay [Boolean] render a fixed overlay to append to a page,
      #   rather than a whole document
      # @param app_root [String] frames under it, outside gems and Ruby's
      #   own library, are the app's
      def initialize(exception, request: nil, overlay: false, app_root: Dir.pwd)
        @exception = exception
        @request = request
        @overlay = overlay
        @app_root = File.join(File.expand_path(app_root), '')
      end

      def view_template
        if @overlay
          report
        else
          doctype
          html(lang: 'en') do
            head do
              meta(charset: 'utf-8')
              meta(name: 'viewport', content: 'width=device-width, initial-scale=1')
              title { "#{@exception.class} · Sidereal" }
            end
            body(style: 'margin: 0') { report }
          end
        end
      end

      private

      def report
        div(id: "sidereal-exception-#{SecureRandom.hex(4)}",
            class: ['sidereal-exception', ('sidereal-exception--overlay' if @overlay)],
            role: ('dialog' if @overlay), aria: { modal: ('true' if @overlay), label: @exception.class.name }) do
          style { raw safe(STYLES) }
          div(class: 'sidereal-exception__inner') do
            render_header
            render_source
            render_backtrace
            render_causes
            render_request if @request
          end
        end
      end

      def render_header
        div(class: 'sidereal-exception__bar') do
          span { "Unhandled exception · #{Sidereal.environment}" }
          if @overlay
            button(type: 'button', class: 'sidereal-exception__close',
                   data: { 'on:click' => "el.closest('.sidereal-exception').remove()" }) { 'Close' }
          end
        end
        h1 { @exception.class.name }
        pre(class: 'sidereal-exception__message') { @exception.message }
      end

      def render_source
        frame = frames.find(&:source?)
        return unless frame

        lines = File.readlines(frame.path, chomp: true)
        first = [frame.lineno - SOURCE_CONTEXT, 1].max
        last = [frame.lineno + SOURCE_CONTEXT, lines.size].min

        h2 { 'Source' }
        p(class: 'sidereal-exception__source-file') { code { "#{relative(frame.path)}:#{frame.lineno}" } }
        pre(class: 'sidereal-exception__source') do
          (first..last).each do |lineno|
            span(class: ('is-current' if lineno == frame.lineno)) do
              b { lineno.to_s }
              plain lines[lineno - 1]
            end
          end
        end
      end

      def render_backtrace
        app_frames = frames.select(&:app)
        h2 { 'Backtrace' }
        frame_list(app_frames.empty? ? frames : app_frames)
        return if app_frames.empty? || app_frames.size == frames.size

        details do
          summary { "Full backtrace (#{frames.size} frames)" }
          frame_list(frames)
        end
      end

      def frame_list(list)
        ol(class: 'sidereal-exception__frames') do
          list.each do |frame|
            li(class: ('is-app' if frame.app)) { code { frame.app ? relative(frame.line) : frame.line } }
          end
        end
      end

      def render_causes
        cause = @exception.cause
        return unless cause

        h2 { 'Caused by' }
        while cause
          p do
            strong { cause.class.name }
            plain ": #{cause.message}"
          end
          cause = cause.cause
        end
      end

      def render_request
        h2 { 'Request' }
        dl do
          dt { 'Method' }
          dd { code { @request.request_method } }
          dt { 'Path' }
          dd { code { @request.fullpath } }
          if @request.get_header('HTTP_DATASTAR_REQUEST')
            dt { 'Datastar' }
            dd { 'yes' }
          end
        end
      end

      def frames
        @frames ||= (@exception.backtrace || []).map { |line| Frame.parse(line, @app_root) }
      end

      def relative(text) = text.delete_prefix(@app_root)
    end
  end
end
