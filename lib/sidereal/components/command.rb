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

      # @param command [Class<Sidereal::Message>, Sidereal::Message] the command
      #   to submit. A class renders a blank form; an instance renders its
      #   payload into the fields, each value encoded to the String an +<input>+
      #   carries by +context.forms_codec+ (see {Sidereal::FormsCodec}).
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
      def initialize(command, attrs = {})
        @on = [attrs.delete(:on) || 'submit'].flatten
        @href = attrs.delete(:href) || '/commands'
        @ajax = attrs.key?(:ajax) ? attrs.delete(:ajax) : true
        @key = attrs.delete(:key) || 'cmd'
        @command = command.is_a?(Class) ? command.new : command
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
      # Values are given as Ruby values and encoded on the way into the +value+
      # attribute, so a Date or Time reaches the browser in the form the codec
      # decodes rather than in whatever +#to_s+ happens to render. They are
      # encoded as attributes *of this command* — merged into it and run through
      # the same pass that renders the visible fields — so a hidden field and a
      # text field carrying the same attribute always agree.
      #
      # @param fields [Hash{Symbol=>Object}] payload key/value pairs
      # @raise [ArgumentError] if the payload declares no such attribute
      # @return [void]
      # @example
      #   f.payload_fields(todo_id: todo.todo_id, done: true)
      def payload_fields(fields = {})
        encoded = encode_payload(command.with_payload(fields), declared: fields.keys)

        fields.each_key do |key|
          input(type: 'hidden', name: "command[payload][#{key}]", value: encoded[key.to_sym])
        end
      end

      # A text input bound to +command[payload][name]+, wrapped for error
      # streaming.
      #
      # @param name [Symbol, String] the payload attribute name
      # @param args [Hash] extra attributes merged onto the +<input>+; an
      #   explicit +:value+ wins over the command's own
      # @return [void]
      # @example
      #   f.text_field :title, placeholder: 'What needs doing?'
      def text_field(name, args = {})
        with_errors(name) do |id|
          input(value: form_value(name), **args.merge(id:, type: 'text', name: "command[payload][#{name}]"))
        end
      end

      # A +<textarea>+ bound to +command[payload][name]+, wrapped for error
      # streaming.
      #
      # A textarea carries its value as element content rather than a +value+
      # attribute, so the encoded value is rendered inside the tag; an unset
      # attribute renders an empty element.
      #
      # @param name [Symbol, String] the payload attribute name
      # @param args [Hash] extra attributes merged onto the +<textarea>+
      # @return [void]
      # @example
      #   f.text_area :body, rows: 6, placeholder: 'Say something'
      def text_area(name, args = {})
        with_errors(name) do |id|
          textarea(**args.merge(id:, name: "command[payload][#{name}]")) { form_value(name) }
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
          input(value: form_value(name), **args.merge(id:, type: 'number', name: "command[payload][#{name}]"))
        end
      end

      # A date input bound to +command[payload][name]+, wrapped for error
      # streaming.
      #
      # The browser submits +YYYY-MM-DD+, which is the form the codec decodes
      # into a Date and the form it encodes one back to — so a +Types::Date+
      # attribute round-trips with no conversion of your own.
      #
      # @param name [Symbol, String] the payload attribute name
      # @param args [Hash] extra attributes merged onto the +<input>+
      # @return [void]
      def date_field(name, args = {})
        with_errors(name) do |id|
          input(value: form_value(name), **args.merge(id:, type: 'date', name: "command[payload][#{name}]"))
        end
      end

      # A checkbox bound to +command[payload][name]+, wrapped for error
      # streaming.
      #
      # Two inputs share the name, because an unchecked box submits nothing at
      # all. Rack keeps the last value for a repeated key, so a checked box
      # sends +"1"+ and an unchecked one the hidden +"0"+ — the two strings
      # Plumb's Forms codec reads as +true+ and +false+.
      #
      # @param name [Symbol, String] the payload attribute name
      # @param args [Hash] extra attributes merged onto the +<input>+
      # @return [void]
      def check_box(name, args = {})
        with_errors(name) do |id|
          input(type: 'hidden', name: "command[payload][#{name}]", value: '0')
          input(
            checked: payload_value(name) == true,
            **args.merge(id:, type: 'checkbox', value: '1', name: "command[payload][#{name}]")
          )
        end
      end

      # The command being rendered, holding its Ruby values — a Boolean is
      # +true+, a Date a Date. Only what an +<input>+ literally carries is ever a
      # String, so form blocks can branch on this directly.
      #
      # @return [Sidereal::Message]
      attr_reader :command

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

      # One attribute's Ruby value, for the field helpers that branch on a value
      # rather than render it (a checkbox's +checked+).
      #
      # @param name [Symbol, String] the payload attribute name
      # @return [Object, nil] nil when the command declares no payload, or the
      #   attribute is unset
      def payload_value(name)
        command.payload&.to_h&.[](name.to_sym)
      end

      # The same value as the String the +value+ attribute carries, from the one
      # encode pass. An attribute that is unset — or that the command holds in a
      # form the codec cannot render — is absent, so no +value+ is emitted at all,
      # which is what a blank field wants.
      #
      # @param name [Symbol, String] the payload attribute name
      # @return [String, nil]
      def form_value(name)
        form_values[name.to_sym]
      end

      # Encoded once per render, not once per field. The codec resolves the whole
      # payload in a single pass, which shares work across attributes and — being
      # non-raising and per-key — copes with the blank and half-filled commands
      # every form is rendered from.
      def form_values
        @form_values ||= encode_payload(command)
      end

      # @param message [Sidereal::Message] the command whose payload to encode
      # @param declared [Array<Symbol>, nil] attribute names to verify against the
      #   payload schema first. +#with_payload+ drops keys the payload does not
      #   declare, which would silently render an empty hidden field.
      # @return [Hash{Symbol => String}] only the attributes that could be encoded
      def encode_payload(message, declared: nil)
        if declared
          unknown = declared.map(&:to_sym) - message.class.payload_attribute_names
          unless unknown.empty?
            raise ArgumentError, "#{message.type} declares no payload attribute #{unknown.join(', ')}"
          end
        end

        encoded = context.forms_codec.encode_payload(message).value
        # A command declaring no payload encodes to the empty string the Forms
        # codec renders nil as, not to a hash of attributes. It has no fields.
        encoded.is_a?(Hash) ? encoded : BLANK_HASH
      end
    end
  end
end
