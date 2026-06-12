# frozen_string_literal: true

require_relative 'base_component'

module Sidereal
  module Components
    # Phlex form component for submitting a {Sidereal::Message} command to the
    # server. Renders a +<form>+ with hidden +command[type]+ / +command[_cid]+
    # inputs and, by default, posts via Datastar's +@post('/commands')+ so the
    # submission is an AJAX request and the response streams back over SSE.
    #
    # Field helpers ({#text_field}, {#number_field}, {#check_box}) wrap each
    # input in a +.command-field+ div alongside an empty error +<span>+, so the
    # server can stream Plumb validation errors back to the exact field (see
    # +Sidereal::App#patch_command_errors+).
    #
    # == Stable element ids
    #
    # Every element id derives from a deterministic prefix (+@cid+) built from
    # the command type and an optional +:key+ — never a random value. This
    # matters because the browser morphs SSE updates by element +id+: a stable
    # id lets idiomorph patch a field *in place* (preserving focus/caret)
    # instead of replacing it. The same property holds when a single command
    # form is re-rendered on its own (an SSE response that morphs just that form
    # back into the page), since the id depends only on +(type, key, field)+ and
    # not on render order.
    #
    # When the same command type is rendered more than once on a page (e.g. a
    # "remove" button per list item), pass a distinct +:key+ so the ids don't
    # collide. Without a +:key+ the prefix defaults to +"cmd"+, which is fine
    # for a single instance.
    #
    # Rendered via the +command+ helper in {BaseComponent}.
    #
    # @example A single form
    #   command AddTodo do |f|
    #     f.text_field :title
    #     button(type: :submit) { 'Add' }
    #   end
    #   # ids: todos_add_todo-cmd-title, ...-wrapper, ...-errors
    #
    # @example Multiple instances of one command type — disambiguate with :key
    #   @todos.each do |todo|
    #     command RemoveTodo, key: todo.todo_id do |f|
    #       f.payload_fields(todo_id: todo.todo_id)
    #       button(type: :submit) { '✓' }
    #     end
    #   end
    #   # ids per row: todos_remove_todo-<todo_id>-...
    #
    # @example Non-AJAX form (plain POST, no Datastar)
    #   command CreateGame, ajax: false do |f|
    #     button(type: :submit) { 'New game' }
    #   end
    class Command < BaseComponent
      # Immutable id builder. {#sub} appends a +-suffix+ segment, so a prefix
      # like +"todos_add_todo-cmd"+ grows into +"todos_add_todo-cmd-title"+ then
      # +"...-wrapper"+ / +"...-errors"+.
      LocalID = Data.define(:name) do
        # @return [String] the id
        def to_s = name

        # @param n [#to_s] the suffix segment to append
        # @return [LocalID] a new id with +-n+ appended
        def sub(n)
          self.class.new("#{name}-#{n}")
        end
      end

      # The +<span>+ that holds a field's validation errors. Rendered empty on
      # first paint (id +"<field_id>-errors"+) so the server can later target it
      # by id and stream error text into it over SSE.
      class ErrorMessages < Phlex::HTML
        # @param field_id [#to_s] the field's id prefix (errors id is derived from it)
        # @param errors [String, Array<String>] error message(s); joined with ", "
        def initialize(field_id, errors = [])
          @id = [field_id, 'errors'].join('-')
          @errors = Array(errors).join(', ')
        end

        def view_template
          span(id: @id, class: 'command-field__errors') { @errors }
        end
      end

      # @param command_class [Class<Sidereal::Message>] the command to submit;
      #   instantiated to read its {Sidereal::Message#type}
      # @param attrs [Hash] form attributes; the following keys are consumed and
      #   the rest are passed through to the +<form>+ element:
      # @option attrs [String, Array<String>] :on ('submit') DOM event(s) that
      #   trigger submission
      # @option attrs [String] :href ('/commands') the endpoint to post to
      # @option attrs [Boolean] :ajax (true) when true, submit via Datastar
      #   +@post+ over SSE; when false, render a plain HTML +action+/+method+ form
      # @option attrs [#to_s] :key ('cmd') discriminator for the id prefix — pass
      #   a stable, per-instance value when the same command type is rendered
      #   multiple times on one page
      def initialize(command_class, attrs = {})
        @on = [attrs.delete(:on) || 'submit'].flatten
        @href = attrs.delete(:href) || '/commands'
        @ajax = attrs.key?(:ajax) ? attrs.delete(:ajax) : true
        @key = attrs.delete(:key) || 'cmd'
        @command = command_class.new
        @attrs = attrs
        # Deterministic id prefix so the same form morphs in place across
        # re-renders (random ids would make idiomorph replace the elements).
        # Pass a distinct :key to disambiguate multiple instances of the same
        # command type on one page.
        @cid = LocalID.new([sanitize_id(@command.type), sanitize_id(@key)].join('-'))
      end

      def view_template
        data = @attrs.fetch(:data, {})
        if @ajax
          local_data = {
            'indicator-fetching' => true
          }
          @on.each do |event|
            local_data["on:#{event}"] = %(@post('#{context.url(@href)}', {contentType: 'form'}))
          end
          data.merge!(local_data)
        else
          @attrs[:action] = context.url(@href)
          @attrs[:method] = @on.include?('submit') ? 'post' : @on.first
        end
        attrs = @attrs.merge(data:)

        form(**attrs) do
          input(type: 'hidden', name: 'command[type]', value: command.type)
          input(type: 'hidden', name: 'command[_cid]', value: @cid.to_s)

          yield
        end
      end

      # Emit hidden +command[payload][...]+ inputs for values the user does not
      # edit (ids carried from the loop variable, fixed amounts, etc.). These
      # have no wrapper or error +<span>+ — use {#text_field} et al. for fields
      # that need validation feedback.
      #
      # @param fields [Hash{Symbol=>Object}] payload key/value pairs
      # @return [void]
      # @example
      #   f.payload_fields(todo_id: todo.todo_id, done: true)
      def payload_fields(fields = {})
        fields.each do |key, value|
          input(type: 'hidden', name: "command[payload][#{key}]", value:)
        end
      end

      # A text input bound to +command[payload][name]+, wrapped for error
      # streaming.
      #
      # @param name [Symbol, String] the payload attribute name
      # @param args [Hash] extra attributes merged onto the +<input>+
      # @return [void]
      # @example
      #   f.text_field :title, placeholder: 'What needs doing?'
      def text_field(name, args = {})
        with_errors(name) do |id|
          input **args.merge(id:, type: 'text', name: "command[payload][#{name}]")
        end
      end

      # A number input bound to +command[payload][name]+, wrapped for error
      # streaming.
      #
      # @param name [Symbol, String] the payload attribute name
      # @param args [Hash] extra attributes merged onto the +<input>+
      # @return [void]
      def number_field(name, args = {})
        with_errors(name) do |id|
          input **args.merge(id:, type: 'number', name: "command[payload][#{name}]")
        end
      end

      # A checkbox bound to +command[payload][name]+, wrapped for error
      # streaming.
      #
      # @param name [Symbol, String] the payload attribute name
      # @param args [Hash] extra attributes merged onto the +<input>+
      # @return [void]
      def check_box(name, args = {})
        with_errors(name) do |id|
          input **args.merge(id: ,type: 'checkbox', name: "command[payload][#{name}]")
        end
      end

      private

      # Make a value safe to embed in a DOM id by collapsing any char outside
      # +[A-Za-z0-9_-]+ to +_+ (so a dotted command type like
      # +"todos.add_todo"+ becomes +"todos_add_todo"+). The dotted type is left
      # intact in the +command[type]+ hidden field — only ids are sanitized.
      #
      # @param value [#to_s]
      # @return [String]
      def sanitize_id(value) = value.to_s.gsub(/[^A-Za-z0-9_-]/, '_')

      # Render a field inside its +.command-field+ wrapper, yielding the field
      # id and appending an empty {ErrorMessages} span. Produces the three
      # coordinated ids the SSE error path targets: +<cid>-<name>+ (input),
      # +<cid>-<name>-wrapper+ (div), +<cid>-<name>-errors+ (span).
      #
      # @param name [Symbol, String] the field name
      # @yieldparam id [String] the input's id
      # @return [void]
      def with_errors(name, &)
        #[cid]-[name]
        field_id = @cid.sub(name)

        # [cid]-[name]-wrapper
        div id: field_id.sub('wrapper').to_s, class: 'command-field' do
          yield field_id.to_s
          #[cid]-[name]-errors
          render ErrorMessages.new(field_id)
        end
      end

      attr_reader :command, :hidden_payload
    end
  end
end
