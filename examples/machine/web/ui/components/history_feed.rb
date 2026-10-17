# frozen_string_literal: true

module UI
  module Components
    # A stream's messages in log order, each linking to the page as it was
    # once that message was in its history. The arrows step back and forth from
    # the step on screen. Commands, transitions (which move a machine) and
    # data events (which only change its domain state) are marked apart.
    class HistoryFeed < Sidereal::Components::BaseComponent
      # @param messages [Array<Sourced::Message>]
      # @param current_step [Integer] the step on screen; the last one while live
      # @param live [Boolean]
      # @param live_href [String] the live page
      # @param step_href [#call(Integer)] the page at a step
      # @param prefix [String, nil] a message type prefix to leave out
      # @param hide [Array<Symbol>] payload keys every message carries, left out
      # @param label [#call(Sourced::Message), nil] a short name for what a message is about, shown before its type
      def initialize(messages:, current_step:, live:, live_href:, step_href:, prefix: nil, hide: [], label: nil)
        @messages = messages
        @current_step = current_step
        @live = live
        @live_href = live_href
        @step_href = step_href
        @prefix = prefix
        @hide = hide
        @label = label
      end

      def view_template
        aside(id: 'history', class: 'history', aria: { label: 'History' }) do
          header(class: 'history__header') do
            h2(class: 'history__title') { 'History' }
            render_pager
          end
          p(class: 'history__status') do
            if @live
              span(class: 'history__live') { 'Live' }
              plain " · #{@messages.size} messages"
            else
              plain "Step #{@current_step} of #{@messages.size} · "
              a(href: @live_href) { 'back to live' }
            end
          end

          if @messages.empty?
            p(class: 'history__empty') { 'No messages yet.' }
          else
            ol(class: 'history__items', reversed: true) do
              @messages.each_with_index.reverse_each do |message, index|
                render_row(message, index + 1)
              end
            end
          end
        end
      end

      private

      def render_pager
        nav(class: 'history__pager', aria: { label: 'Step through history' }) do
          pager_link('←', @current_step - 1, 'Previous step')
          pager_link('→', @current_step + 1, 'Next step')
        end
      end

      def pager_link(label, step, title)
        if step.between?(1, @messages.size) && !(@live && step > @current_step)
          a(class: 'history__arrow', href: @step_href.call(step), title:, aria: { label: title }, data: travel(step)) { label }
        else
          span(class: 'history__arrow history__arrow--disabled', aria: { hidden: 'true' }) { label }
        end
      end

      def render_row(message, step)
        kind = kind_of(message)
        current = step == @current_step
        future = step > @current_step
        li(class: ['history__item', "history__item--#{kind}", ('is-current' if current), ('is-future' if future)]) do
          a(class: 'history__link', href: @step_href.call(step), aria: { current: current ? 'step' : nil }, data: travel(step)) do
            span(class: 'history__step') { step.to_s }
            span(class: 'history__body') do
              span(class: 'history__type') do
                span(class: 'history__kind') { kind.to_s }
                if (about = @label&.call(message))
                  span(class: 'history__about') { about }
                end
                plain(@prefix ? message.type.delete_prefix(@prefix) : message.type)
              end
              summary = payload_summary(message)
              span(class: 'history__payload') { summary } unless summary.empty?
            end
            time(class: 'history__time', datetime: message.created_at.iso8601) do
              message.created_at.localtime.strftime('%H:%M:%S')
            end
          end
        end
      end

      # A step link patches the page in place (the step routes answer a Datastar
      # request with the page and push its URL) instead of loading it. The href
      # stays, for a new tab.
      def travel(step) = { 'on:click__prevent' => "@get('#{@step_href.call(step)}')" }

      def kind_of(message)
        if message in Sourced::Command then :command
        elsif transition?(message) then :checkpoint
        else :data
        end
      end

      # A machine's checkpoint events (and a child's Started) move it: they
      # record where from and where to.
      def transition?(message)
        (message in Sourced::Machine::State | Sourced::Machine::ChildEvent) && message.payload.respond_to?(:target)
      end

      # A transition as where it went from and to; any other message's payload
      # without the keys every message carries, and a card number masked down
      # to its last four digits.
      def payload_summary(message)
        return "#{message.payload.source} → #{message.payload.target}" if transition?(message)

        message.payload.to_h.except(*@hide).map do |key, value|
          value = "•••• #{value.to_s.delete(' ')[-4..]}" if key == :card_number
          "#{key}: #{value}"
        end.join(' · ')
      end
    end
  end
end
