# frozen_string_literal: true

require 'sidereal'

# In-memory store (good enough for a demo)
TODOS = {}

# -- Messages --

AddTodo = Sidereal::Message.define('todos.add') do
  attribute :todo_id, Sidereal::Types::AutoUUID
  attribute :title, Sidereal::Types::String.present
end

Notify = Sidereal::Message.define('todos.notify') do
  attribute :message, String
end

RemoveTodo = Sidereal::Message.define('todos.remove') do
  attribute :todo_id, Sidereal::Types::UUID::V4
end

require_relative 'ui/layout'
require_relative 'ui/todo_page'

# -- App --

class TodoApp < Sidereal::App
  session secret: 'a' * 64

  layout Layout

  command AddTodo do |cmd|
    TODOS[cmd.payload.todo_id] = cmd.payload
    dispatch Notify, message: "Done: #{cmd.payload.todo_id}"
  end

  command Notify do |cmd|
    Console.info "NOTI #{cmd}"
    sleep 3
  end

  command RemoveTodo do |cmd|
    TODOS.delete cmd.payload.todo_id
  end

  page TodoPage
end
