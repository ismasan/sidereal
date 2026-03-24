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
      h1 { 'Todos' }

      command AddTodo do |f|
        f.text_field :title
        button(type: :submit, style: 'padding:0.4rem 1rem;') { 'Add' }
      end

      p(id: 'notifications') { '-- ' }

      if @todos.any?
        ul do
          @todos.each do |todo|
            li do
              strong { todo.title }
              command RemoveTodo do |f|
                f.payload_fields(todo_id: todo.todo_id)
                button(type: :submit) { 'x' }
              end
            end
          end
        end
      else
        p(style: 'color:#888;') { 'No todos yet. Add one above!' }
      end
    end
  end
end

