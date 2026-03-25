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
  attribute :role, Sidereal::Types::String.present
  attribute :content, Sidereal::Types::String.present
end

AskLLM = Sidereal::Message.define('chat.ask_llm') do
  attribute :author, Sidereal::Types::String.present
  attribute :role, Sidereal::Types::String.present
  attribute :content, Sidereal::Types::String.present
end

ChatNotify = Sidereal::Message.define('chat.notify') do
  attribute :message, String
end

Working = Sidereal::Message.define('chat.working')

require_relative 'ui/layout'
require_relative 'ui/chat_page'

require 'json'

# -- App --
# File-backed message store (one JSON object per line)
MESSAGES_FILE = 'chat_messages.jsonl'

module MessageLog
  module_function

  def messages
    return [] unless File.exist?(MESSAGES_FILE)

    File.readlines(MESSAGES_FILE, chomp: true).filter_map do |line|
      next if line.empty?
      Sidereal::Message.from(JSON.parse(line, symbolize_names: true))
    end
  end

  def append(msg)
    File.open(MESSAGES_FILE, 'a') { |f| f.puts JSON.dump(msg.to_h) }
  end
end

class ChatApp < Sidereal::App
  session secret: 'b' * 64

  layout ChatLayout

  command SendMessage do |cmd|
    MessageLog.append(cmd)
    if cmd.payload.content.to_s =~ /@bot /
      dispatch AskLLM, cmd.payload
    end
    dispatch ChatNotify, message: "#{cmd.payload.author}: #{cmd.payload.content}"
  end

  command ChatNotify do |cmd|
  end

  command AskLLM do |cmd|
    broadcast Working

    chat = RubyLLM.chat
    # Load recent chat history
    MessageLog.messages.last(50).each do |m|
      chat.add_message role: m.payload.role, content: %(#{m.payload.author} said on #{m.created_at}: #{m.payload.content})
    end
    response = chat.ask(cmd.payload.content)
    dispatch SendMessage, author: 'Bot', role: 'assistant', content: response.content
  end

  page ChatPage
end
