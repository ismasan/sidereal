# frozen_string_literal: true

require 'sidereal'

# -- Messages --

SendMessage = Sidereal::Message.define('chat.send_message') do
  attribute :author, Sidereal::Types::String.present
  attribute :body, Sidereal::Types::String.present
end

ChatNotify = Sidereal::Message.define('chat.notify') do
  attribute :message, String
end

require_relative 'ui/layout'
require_relative 'ui/chat_page'

# -- App --
# In-memory message store (good enough for a demo)
MESSAGES = []

class ChatApp < Sidereal::App
  session secret: 'b' * 64

  layout ChatLayout

  command SendMessage do |cmd|
    MESSAGES << cmd
    dispatch ChatNotify, message: "#{cmd.payload.author}: #{cmd.payload.body}"
  end

  command ChatNotify do |cmd|
  end

  page ChatPage
end
