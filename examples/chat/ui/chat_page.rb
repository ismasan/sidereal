# frozen_string_literal: true

class ChatPage < Sidereal::Page
  path '/'

  on SendMessage do |evt|
    # browser.patch_elements load(params)
    browser.patch_elements MessageBubble.new(evt), mode: 'append', selector: '#messages'
    browser.execute_script %(document.querySelector('[data-target="message-body"]').value = '')
  end

  on ChatNotify do |evt|
    browser.patch_elements ActivityItem.new(evt), mode: 'append', selector: '#activity'
  end

  def self.load(_params, _ctx)
    new(messages: MESSAGES.dup)
  end

  class MessageBubble < Sidereal::Components::BaseComponent
    def initialize(message)
      @message = message
    end

    def view_template
      div(class: 'message-bubble') do
        div(class: 'message-bubble__header') do
          span(class: 'message-bubble__author') { @message.payload.author }
          span(class: 'message-bubble__time') { @message.created_at.strftime('%H:%M') }
        end
        p(class: 'message-bubble__body') { @message.payload.body }
      end
    end
  end

  class ActivityItem < Sidereal::Components::BaseComponent
    def initialize(notification)
      @notification = notification
    end

    def view_template
      div(class: 'feed-item') do
        span(class: 'datetime') { @notification.created_at.strftime('%H:%M:%S') }
        span(class: 'message') { @notification.payload.message }
      end
    end
  end

  def initialize(messages: [])
    @messages = messages
  end

  def view_template
    div(id: 'chat-page') do
      header(class: 'header') do
        h1 { 'Chat' }
      end

      div(class: 'columns') do
        main(class: 'col-main') do
          div(id: 'messages', class: 'message-feed') do
            @messages.each do |msg|
              render MessageBubble.new(msg)
            end
          end

          command SendMessage, class: 'compose-form' do |f|
            div(class: 'compose-form__row') do
              f.text_field :author, placeholder: 'Name'
              f.text_field :body, data: {target: 'message-body'}, placeholder: 'Type a message...'
              button(type: :submit) { 'Send' }
            end
          end
        end

        aside(class: 'col-sidebar') do
          h2 { 'Activity' }
          div(id: 'activity', class: 'feed') do
          end
        end
      end
    end
  end
end
