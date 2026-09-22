# frozen_string_literal: true

# The app's message types. Kept apart from app.rb so tooling that only needs
# to build messages (the Rakefile's db:seed) can load them without the LLM
# client and its API key.

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
