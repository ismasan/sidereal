# frozen_string_literal: true

require 'sidereal'

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
# In-memory store (good enough for a demo)
Todo = Struct.new(:todo_id, :title, :done, keyword_init: true)
TODOS = {}

class TodoApp < Sidereal::App
  session secret: 'a' * 64

  layout Layout

  handle AddTodo
  handle RemoveTodo

  command AddTodo do |cmd|
    TODOS[cmd.payload.todo_id] = Todo.new(todo_id: cmd.payload.todo_id, title: cmd.payload.title, done: false)
    dispatch Notify, message: "Added: #{cmd.payload.title}"
  end

  command Notify do |cmd|
    # Simulate slow operation, IO, APIs, etc
    sleep 3
  end

  command RemoveTodo do |cmd|
    item = TODOS[cmd.payload.todo_id]
    item.done = true
    dispatch Notify, message: "Done: #{item.title}"
  end

  page TodoPage
end


