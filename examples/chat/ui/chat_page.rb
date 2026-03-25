# frozen_string_literal: true

require 'kramdown'

class ChatPage < Sidereal::Page
  path '/'

  on SendMessage do |evt|
    # browser.patch_elements load(params)
    browser.patch_elements MessageList.new(MessageLog.messages)
    # browser.patch_elements MessageBubble.new(evt), mode: 'append', selector: '#messages'
    browser.execute_script %(document.querySelector('[data-target="message-body"]').value = '')
    browser.execute_script %(scrollToBottom('messages'))
  end

  on ChatNotify do |evt|
    browser.patch_elements ActivityItem.new(evt), mode: 'append', selector: '#activity'
  end

  on Working do |evt|
    browser.patch_elements %(<p class="thinking">Thinking...</p>), mode: 'append', selector: '#messages'
    browser.execute_script %(scrollToBottom('messages'))
  end

  def self.load(_params, _ctx)
    new(messages: MessageLog.messages)
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
        div(class: 'message-bubble__body') do
          raw safe(Kramdown::Document.new(@message.payload.content).to_html)
        end
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

  class MessageList < Sidereal::Components::BaseComponent
    def initialize(messages)
      @messages = messages
    end

    def view_template
      div(id: 'messages', class: 'message-feed', data: _d.init.run(%(scrollToBottom('messages'))).to_h) do
        @messages.each do |msg|
          render MessageBubble.new(msg)
        end
      end
    end
  end

  def initialize(messages: [])
    @messages = messages
  end

  JS = <<~CODE
  function scrollToBottom(id) {
    const el = document.getElementById(id); 
    el.scrollTop = el.scrollHeight
  }
  CODE

  def view_template
    div(id: 'chat-page') do
      header(class: 'header') do
        h1 { 'Chat' }
      end

      script do
        safe JS  
      end

      div(class: 'columns') do
        main(class: 'col-main') do
          render MessageList.new(@messages)

          command SendMessage, class: 'compose-form' do |f|
            div(class: 'compose-form__row') do
              f.text_field :author, placeholder: 'Name'
              f.payload_fields(role: 'user')
              f.text_field :content, data: {target: 'message-body'}, placeholder: 'Type a message...'
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
