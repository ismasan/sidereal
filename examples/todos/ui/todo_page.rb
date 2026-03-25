# frozen_string_literal: true

class TodoPage < Sidereal::Page
  path '/'

  # Re-render the page when a todo is added
  on AddTodo do |_evt|
    browser.patch_elements load(params)
  end

  on Notify do |cmd|
    browser.patch_elements %(<p id="notifications">#{cmd.payload.message}</p>)
  end

  on RemoveTodo do |_evt|
    browser.patch_elements load(params)
  end

  def self.load(_params, _ctx)
    new(todos: TODOS.values.dup)
  end

  def initialize(todos: [])
    @todos = todos
  end

  def view_template
    div(id: 'todos-page', data: _d.signals(page_key: self.class.page_key, params: {}).to_h) do
      header(class: 'header') do
        h1 { 'Todos' }
      end

      command AddTodo, class: 'add-form' do |f|
        div(class: 'add-form__row') do
          f.text_field :title, placeholder: 'What needs to be done?'
          button(type: :submit) { 'Add' }
        end
      end

      p(id: 'notifications', class: 'notification') { '' }

      if @todos.any?
        div(class: 'todo-count') do
          span { "#{@todos.size} #{@todos.size == 1 ? 'item' : 'items'}" }
        end
        ul(class: 'todo-list') do
          @todos.each do |todo|
            li(class: 'todo-item') do
              span(class: 'todo-item__title') { todo.title }
              command RemoveTodo, class: 'todo-item__remove' do |f|
                f.payload_fields(todo_id: todo.todo_id)
                button(type: :submit, class: 'btn-remove') { "\u00d7" }
              end
            end
          end
        end
      else
        div(class: 'empty-state') do
          p { 'No todos yet.' }
          p { 'Add one above to get started.' }
        end
      end
    end
  end
end

