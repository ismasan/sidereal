# frozen_string_literal: true

require 'kramdown'

class ChatPage < Sidereal::Page
  path '/'

  ROOM_NAME = 'Sidereal room'
  BOT_NAME = 'Bot'

  on SendMessage do |_evt|
    browser.patch_elements MessageList.new(MessageLog.messages, username: context.session[:username])
    browser.execute_script %(document.querySelector('[data-target="message-body"]').value = '')
    browser.execute_script %(scrollToBottom('messages'))
  end

  on ChatNotify do |evt|
    browser.patch_elements ActivityItem.new(evt), mode: 'append', selector: '#activity'
  end

  on Working do |_evt|
    browser.patch_elements TypingIndicator.new, mode: 'append', selector: '#messages'
    browser.execute_script %(scrollToBottom('messages'))
  end

  def self.load(_params, ctx)
    new(messages: MessageLog.messages, username: ctx.session[:username])
  end

  # Deterministic per-author colour, the way group chats tell speakers apart.
  # Six hues, picked by a stable hash of the name so a given author keeps
  # their colour across renders and processes.
  module AuthorColor
    COUNT = 6

    def self.index(name)
      name.to_s.each_byte.sum % COUNT
    end

    def self.initial(name)
      name.to_s.strip[0]&.upcase || '?'
    end
  end

  # Who is speaking, from the message's role: a person gets their initial in
  # their colour, the bot a robot, the app itself (schedules, clocks) a bolt.
  class Avatar < Sidereal::Components::BaseComponent
    def initialize(name, role: 'user')
      @name = name
      @role = role
    end

    def view_template
      case @role
      when 'assistant'
        span(class: 'avatar avatar--bot', aria_hidden: 'true') do
          svg(viewBox: '0 0 24 24', width: '18', height: '18', fill: 'none', stroke: 'currentColor',
              stroke_width: '1.8', stroke_linecap: 'round', stroke_linejoin: 'round') do |s|
            s.rect(x: '4', y: '8', width: '16', height: '12', rx: '3')
            s.path(d: 'M12 8V4M9 4h6')
            s.circle(cx: '9', cy: '14', r: '1', fill: 'currentColor')
            s.circle(cx: '15', cy: '14', r: '1', fill: 'currentColor')
          end
        end
      when 'system'
        span(class: 'avatar avatar--system', aria_hidden: 'true') do
          svg(viewBox: '0 0 24 24', width: '16', height: '16', fill: 'currentColor') do |s|
            s.path(d: 'M13 2 4 14h6l-1 8 9-12h-6z')
          end
        end
      else
        span(class: "avatar avatar--c#{AuthorColor.index(@name)}", aria_hidden: 'true') do
          AuthorColor.initial(@name)
        end
      end
    end
  end

  # One message row. Consecutive messages from one author form a run: the
  # +first+ bubble carries the name, the +last+ one the avatar and the tail.
  class MessageBubble < Sidereal::Components::BaseComponent
    def initialize(message, mine: false, first: true, last: true)
      @message = message
      @mine = mine
      @first = first
      @last = last
    end

    def view_template
      author = @message.payload.author
      role = @message.payload.role
      classes = ['msg']
      classes << (@mine ? 'msg--mine' : 'msg--theirs')
      classes << 'msg--first' if @first
      classes << 'msg--last' if @last
      classes << 'msg--bot' if role == 'assistant'

      div(class: classes.join(' ')) do
        unless @mine
          div(class: 'msg__avatar') { render Avatar.new(author, role:) if @last }
        end

        div(class: 'msg__bubble') do
          if @first && !@mine
            span(class: "msg__author author-c#{AuthorColor.index(author)}") { author }
          end
          div(class: 'msg__body') do
            raw safe(Kramdown::Document.new(@message.payload.content).to_html)
          end
          time(class: 'msg__time', datetime: @message.created_at.iso8601) do
            @message.created_at.strftime('%H:%M')
          end
        end
      end
    end
  end

  class DateDivider < Sidereal::Components::BaseComponent
    def initialize(date)
      @date = date
    end

    def view_template
      div(class: 'day') { span(class: 'day__label') { label } }
    end

    private

    def label
      today = Date.today
      case @date
      when today then 'Today'
      when today - 1 then 'Yesterday'
      else @date.strftime('%A, %-d %B')
      end
    end
  end

  class TypingIndicator < Sidereal::Components::BaseComponent
    def view_template
      div(class: 'msg msg--theirs msg--first msg--last msg--bot msg--typing') do
        div(class: 'msg__avatar') { render Avatar.new(BOT_NAME, role: 'assistant') }
        div(class: 'msg__bubble', role: 'status', aria_label: 'Bot is typing') do
          span(class: 'typing') { 3.times { span(class: 'typing__dot') } }
        end
      end
    end
  end

  class ActivityItem < Sidereal::Components::BaseComponent
    def initialize(notification)
      @notification = notification
    end

    def view_template
      div(class: 'activity__item') do
        time(class: 'activity__time', datetime: @notification.created_at.iso8601) do
          @notification.created_at.strftime('%H:%M:%S')
        end
        span(class: 'activity__text') { @notification.payload.message }
      end
    end
  end

  class MessageList < Sidereal::Components::BaseComponent
    # Consecutive messages from one author closer together than this are
    # shown as one run: name and avatar once, bubbles stacked beneath.
    GROUP_WINDOW = 5 * 60

    def initialize(messages, username: nil)
      @messages = messages
      @username = username
    end

    def view_template
      div(id: 'messages', class: 'thread', data: _d.init.run(%(scrollToBottom('messages'))).to_h) do
        if @messages.empty?
          div(class: 'thread__empty') do
            p { 'Nobody has said anything yet.' }
            p { 'Say hello, or ask @bot a question.' }
          end
        end

        @messages.each_with_index do |msg, i|
          previous = i.zero? ? nil : @messages[i - 1]
          following = @messages[i + 1]

          if previous.nil? || previous.created_at.to_date != msg.created_at.to_date
            render DateDivider.new(msg.created_at.to_date)
          end

          render MessageBubble.new(
            msg,
            mine: msg.payload.author == @username,
            first: !continues?(previous, msg),
            last: following.nil? || !continues?(msg, following)
          )
        end
      end
    end

    private

    # Is +msg+ a continuation of +previous+ — same speaker, close in time,
    # on the same day? The app's own messages (schedules, clocks) each
    # stand alone: every one is its own bubble.
    def continues?(previous, msg)
      return false if previous.nil?
      return false if previous.payload.role == 'system' || msg.payload.role == 'system'
      return false if previous.payload.author != msg.payload.author
      return false if previous.created_at.to_date != msg.created_at.to_date

      (msg.created_at - previous.created_at) < GROUP_WINDOW
    end
  end

  class LoginView < Sidereal::Components::BaseComponent
    def view_template
      div(class: 'join') do
        div(class: 'join__card') do
          span(class: 'room-mark room-mark--lg', aria_hidden: 'true') { '#' }
          h1(class: 'join__title') { 'Join the room' }
          p(class: 'join__hint') { 'Pick a name so everyone knows who is talking.' }
          command Login, class: 'join__form' do |f|
            f.text_field :username, placeholder: 'Your name', autocomplete: 'nickname', autofocus: true
            button(type: :submit, class: 'btn btn--primary') { 'Join' }
          end
        end
      end
    end
  end

  def initialize(messages: [], username: nil)
    @messages = messages
    @username = username
  end

  JS = <<~CODE
    function scrollToBottom(id) {
      const el = document.getElementById(id);
      if (el) el.scrollTop = el.scrollHeight;
    }
  CODE

  def view_template
    div(id: 'chat-page', class: 'app') do
      if @username.to_s.empty?
        render LoginView.new
      else
        script { safe JS }

        header(class: 'topbar') do
          span(class: 'room-mark', aria_hidden: 'true') { '#' }
          div(class: 'topbar__titles') do
            h1(class: 'topbar__title') { ROOM_NAME }
            p(class: 'topbar__subtitle') { "Chatting as #{@username}" }
          end
        end

        main(class: 'conversation') do
          render MessageList.new(@messages, username: @username)

          div(class: 'composer') do
            command SendMessage, class: 'composer__form' do |f|
              f.text_field :content,
                           data: { target: 'message-body' },
                           placeholder: 'Message the room, or @bot to ask the bot',
                           autocomplete: 'off',
                           autofocus: true
              button(type: :submit, class: 'composer__send', aria_label: 'Send') do
                svg(viewBox: '0 0 24 24', width: '20', height: '20', fill: 'currentColor', aria_hidden: 'true') do |s|
                  s.path(d: 'M3.4 20.4 21.7 12 3.4 3.6l-.1 6.6L15 12 3.3 13.8z')
                end
              end
            end
          end
        end

        aside(class: 'activity') do
          h2(class: 'activity__title') { 'Activity' }
          div(id: 'activity', class: 'activity__feed') do
            p(class: 'activity__empty') { 'What happens in the room shows up here.' }
          end
        end
      end
    end
  end
end
