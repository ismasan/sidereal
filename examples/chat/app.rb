# frozen_string_literal: true

require 'dotenv'
Dotenv.load '.env'

require 'sidereal'
require 'sidereal/pubsub/unix'
require 'sidereal/store/file_system'
require 'sidereal/elector/file_system'
require 'ruby_llm'

Sidereal.configure do |c|
  c.workers = 3
  c.store = Sidereal::Store::FileSystem.new(root: 'tmp/sidereal-store')
  c.pubsub = Sidereal::PubSub::Unix.new
  # Only one process per host runs scheduled blocks. Drop this line and
  # the default AlwaysLeader elector fires schedules in every process.
  c.elector = Sidereal::Elector::FileSystem.new(lock_path: 'tmp/sidereal-leader.lock')
end

RubyLLM.configure do |config|
  # Add keys ONLY for the providers you intend to use.
  # Using environment variables is highly recommended.
  config.openai_api_key = ENV.fetch('OPENAI_API_KEY')
  # config.anthropic_api_key = ENV.fetch('ANTHROPIC_API_KEY')
end
# -- Messages --

Login = Sidereal::Message.define('chat.login') do
  attribute :username, Sidereal::Types::String.present
end

SendMessage = Sidereal::Message.define('chat.send_message') do
  attribute :author, Sidereal::Types::String.default('')
  attribute :role, Sidereal::Types::String.default('user')
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

SendEmails = Sidereal::Message.define('chat.send_emails') do
  attribute? :kickoff, Sidereal::Types::Boolean
  attribute? :sender,  Sidereal::Types::String
end

EndCampaign = Sidereal::Message.define('chat.end_campaign')

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

  before_command do |cmd|
    cmd.with_payload(author: session[:username].to_s, role: 'user')
  end

  handle Login do |cmd|
    session[:username] = cmd.payload.username
    browser.patch_elements ChatPage.load(params, self)
  end

  handle SendMessage

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

    response = chat.ask(cmd.payload.content)
    dispatch SendMessage, author: 'Bot', role: 'assistant', content: response.content
  end

  command_helpers do
    private def chat
      @chat ||= (
        chat = RubyLLM.chat
        # Load recent chat history
        MessageLog.messages.last(50).each do |m|
          chat.add_message role: m.payload.role, content: %(#{m.payload.author} said on #{m.created_at}: #{m.payload.content})
        end
        chat
      )
    end
  end

  # User-defined command handlers for an explicit-class schedule.
  command SendEmails do |cmd|
    # etc
  end

  command EndCampaign do |cmd|
    # etc
  end

  # Explicit-class form: each `at` step references a class the user
  # already wired up via `command`. The macro generates no class and
  # defines no handler.
  # schedule 'Flash sale campaign' do
  #   at '2026-05-10T10:00:00', SendEmails, kickoff: true
  #   at 'every day at 9am',    SendEmails, sender: 'acme@company.org'
  #   at '10d',                 EndCampaign
  # end

  # Block form: each `at` step gets an auto-generated class under
  # ChatApp::Commander::Schedules::SchedTickCampaign0Step{0,1,2}, with
  # the block as that class's handler.
  schedule 'Tick campaign' do
    at Time.now + 10 do |cmd|
      dispatch(
        SendMessage,
        author: 'System',
        role: 'system',
        content: "▶ Entered #{cmd.metadata[:schedule_name]} (pid #{Process.pid})"
      )
    end

    at 'every 3 seconds' do |cmd|
      dispatch(
        SendMessage,
        author: 'Clock',
        role: 'system',
        content: "#{cmd.metadata[:producer]}: The time is #{Time.now.strftime('%H:%M:%S')} (pid #{Process.pid})"
      )
    end

    at '10s' do |cmd|
      dispatch(
        SendMessage,
        author: 'Clock',
        role: 'system',
        content: 'Last before exit'
      )
    end

    at '4s' do |cmd|
      dispatch(
        SendMessage,
        author: 'System',
        role: 'system',
        content: "■ Exited #{cmd.metadata[:schedule_name]} (pid #{Process.pid})"
      )
    end
  end

  page ChatPage
end
