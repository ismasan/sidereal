# frozen_string_literal: true

require 'dotenv'
Dotenv.load '.env'

require 'sidereal'
require 'ruby_llm'

Sidereal.configure do |c|
  c.workers = 3
end

RubyLLM.configure do |config|
  # Add keys ONLY for the providers you intend to use.
  # Using environment variables is highly recommended.
  config.openai_api_key = ENV.fetch('OPENAI_API_KEY')
  # config.anthropic_api_key = ENV.fetch('ANTHROPIC_API_KEY')
end
# -- Messages --

SendMessage = Sidereal::Message.define('chat.send_message') do
  attribute :author, Sidereal::Types::String.present
  attribute :body, Sidereal::Types::String.present
end

AskLLM = Sidereal::Message.define('chat.ask_llm') do
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
    if cmd.payload.body.to_s =~ /@bot /
      dispatch AskLLM, cmd.payload
    end
    dispatch ChatNotify, message: "#{cmd.payload.author}: #{cmd.payload.body}"
  end

  command ChatNotify do |cmd|
  end

  command AskLLM do |cmd|
    chat = RubyLLM.chat
    begin
      response = chat.ask(cmd.payload.body)
    rescue Exception => ee
      Console.warn ee
    end
    dispatch SendMessage, author: 'Bot', body: response.content
  end

  page ChatPage
end
