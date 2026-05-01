# frozen_string_literal: true

require 'phlex'

module Sidereal
  module Components
    # Self-contained toast for system failure notifications. Renders into
    # the page via +browser.patch_elements(SystemNotify*.new(evt),
    # mode: 'prepend', selector: 'body')+ from the base {Page}'s default
    # reactions. The +<style>+ tag is included inline so the toast works
    # even without any host-app CSS.
    class SystemNotify < Phlex::HTML
      STYLES = <<~CSS.strip
        #sidereal-sysnotify-stack {
          position: fixed;
          top: 0;
          right: 0;
          z-index: 99999;
          max-width: 32rem;
          max-height: 100vh;
          overflow-y: auto;
        }
        .sidereal-sysnotify {
          font: 13px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
          margin: 0.5rem;
          padding: 0.75rem 1rem;
          background: #fff;
          border-left: 4px solid currentColor;
          border-radius: 4px;
          box-shadow: 0 4px 12px rgba(0,0,0,0.15);
          animation: sidereal-sysnotify-in 220ms cubic-bezier(0.2, 0.7, 0.3, 1);
          transform-origin: top right;
          transition: transform 200ms ease-in, opacity 200ms ease-in;
        }
        @keyframes sidereal-sysnotify-in {
          from { transform: translateX(110%) scale(0.98); opacity: 0; }
          to   { transform: translateX(0)    scale(1);    opacity: 1; }
        }
        .sidereal-sysnotify--leaving {
          transform: translateX(110%) scale(0.98);
          opacity: 0;
          pointer-events: none;
        }
        @media (prefers-reduced-motion: reduce) {
          .sidereal-sysnotify { animation: none; transition: none; }
        }
        .sidereal-sysnotify--retry { color: #d97706; background: #fffbeb; }
        .sidereal-sysnotify--failure { color: #b91c1c; background: #fef2f2; }
        .sidereal-sysnotify__head {
          display: flex; align-items: center; gap: 0.5rem;
          font-weight: 600;
        }
        .sidereal-sysnotify__title { flex: 1; }
        .sidereal-sysnotify__close {
          background: transparent; border: 0; cursor: pointer;
          font-size: 1.2rem; color: inherit; padding: 0 0.5rem;
        }
        .sidereal-sysnotify__close:hover { opacity: 0.7; }
        .sidereal-sysnotify__body { margin-top: 0.5rem; color: #1f2937; }
        .sidereal-sysnotify__error { margin-bottom: 0.25rem; }
        .sidereal-sysnotify__meta {
          font-size: 0.85em; color: #6b7280; margin-top: 0.5rem;
        }
        .sidereal-sysnotify__backtrace summary {
          cursor: pointer; font-size: 0.85em; color: #6b7280;
          margin-top: 0.5rem;
        }
        .sidereal-sysnotify__backtrace pre {
          margin-top: 0.5rem; padding: 0.5rem;
          background: #f3f4f6; border-radius: 4px;
          font-size: 0.8em; overflow-x: auto;
          white-space: pre; line-height: 1.4;
        }
      CSS

      def initialize(message)
        @msg = message
        @payload = message.payload
      end

      def view_template
        div(
          id: "sidereal-sysnotify-#{@msg.id}",
          class: "sidereal-sysnotify sidereal-sysnotify--#{kind}"
        ) do
          style { STYLES }
          div(class: 'sidereal-sysnotify__head') do
            span(class: 'sidereal-sysnotify__icon') { icon }
            span(class: 'sidereal-sysnotify__title') { title }
            button(
              type: 'button',
              class: 'sidereal-sysnotify__close',
              data: { 'on:click' => "(t=>{t.classList.add('sidereal-sysnotify--leaving');setTimeout(()=>t.remove(),220)})(el.closest('.sidereal-sysnotify'))" }
            ) { '×' }
          end
          div(class: 'sidereal-sysnotify__body') do
            div(class: 'sidereal-sysnotify__error') do
              strong { "#{@payload.error_class}: " }
              span { @payload.error_message }
            end
            extra_meta
            render_backtrace if @payload.backtrace.any?
          end
        end
      end

      private

      # Subclasses customize these:
      def kind = raise NotImplementedError
      def icon = raise NotImplementedError
      def title = raise NotImplementedError
      def extra_meta = nil

      def render_backtrace
        details(class: 'sidereal-sysnotify__backtrace') do
          summary { 'Backtrace' }
          pre { @payload.backtrace.join("\n") }
        end
      end
    end

    # Amber toast shown when a handler raised and policy chose to retry.
    class SystemNotifyRetry < SystemNotify
      private

      def kind = 'retry'
      def icon = '⟳'
      def title = "#{@payload.command_type} failed (attempt #{@payload.attempt}, retrying)"

      def extra_meta
        div(class: 'sidereal-sysnotify__meta') do
          plain 'Next attempt at '
          time { @payload.retry_at }
        end
      end
    end

    # Red toast shown when policy chose to dead-letter.
    class SystemNotifyFailure < SystemNotify
      private

      def kind = 'failure'
      def icon = '⛔'
      def title = "#{@payload.command_type} failed permanently"

      def extra_meta
        div(class: 'sidereal-sysnotify__meta') do
          plain "after #{@payload.attempt} attempt(s)"
        end
      end
    end
  end
end
