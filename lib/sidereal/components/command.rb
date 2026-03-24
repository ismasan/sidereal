# frozen_string_literal: true

require_relative 'base_component'

module Sidereal
  module Components
    class Command < BaseComponent
      LocalID = Data.define(:name) do
        def to_s = name

        def sub(n)
          self.class.new("#{name}-#{n}")
        end
      end

      class ErrorMessages < Phlex::HTML
        def initialize(field_id, errors = [])
          @id = [field_id, 'errors'].join('-')
          @errors = Array(errors).join(', ')
        end

        def view_template
          span(id: @id, class: 'command-field__errors') { @errors }
        end
      end

      def initialize(command_class, attrs = {})
        @on = [attrs.delete(:on) || 'submit'].flatten
        @href = attrs.delete(:href) || '/commands'
        @ajax = attrs.key?(:ajax) ? attrs.delete(:ajax) : true
        @command = command_class.new
        @attrs = attrs
        @cid = LocalID.new(['cmd', SecureRandom.hex(3)].join)
      end

      def view_template
        data = @attrs.fetch(:data, {})
        if @ajax
          local_data = {
            'indicator-fetching' => true
          }
          @on.each do |event|
            local_data["on:#{event}"] = %(@post('#{@href}', {contentType: 'form'}))
          end
          data.merge!(local_data)
        else
          @attrs[:action] = @href
          @attrs[:method] = @on.include?('submit') ? 'post' : @on.first
        end
        attrs = @attrs.merge(data:)

        form(**attrs) do
          input(type: 'hidden', name: 'command[type]', value: command.type)
          input(type: 'hidden', name: 'command[_cid]', value: @cid.to_s)

          yield
        end
      end

      def payload_fields(fields = {})
        fields.each do |key, value|
          input(type: 'hidden', name: "command[payload][#{key}]", value:)
        end
      end

      def text_field(name, args = {})
        with_errors(name) do |id|
          input **args.merge(id:, type: 'text', name: "command[payload][#{name}]")
        end
      end

      def number_field(name, args = {})
        with_errors(name) do |id|
          input **args.merge(id:, type: 'number', name: "command[payload][#{name}]")
        end
      end

      def check_box(name, args = {})
        with_errors(name) do |id|
          input **args.merge(id: ,type: 'checkbox', name: "command[payload][#{name}]")
        end
      end

      private

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
