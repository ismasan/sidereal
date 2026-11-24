# frozen_string_literal: true

require 'json'
require 'stringio'
require 'rack/mock_request'
require 'sidereal'

module Sidereal
  # Helpers for testing apps' parts. Not loaded with Sidereal:
  #
  #   require 'sidereal/testing'
  module Testing
    # Runs a component's command handlers (see
    # {Components::BaseComponent.handle}) the way an app does, in a small app
    # of their own, and returns what each did. Works with any test framework.
    #
    #   harness = Sidereal::Testing::Harness.new(Chat)
    #   result = harness.handle(SendMessage, { text: 'hi' }, session: { 'user' => 'ada' })
    #
    #   result.status       # => 200
    #   result.command      # => #<SendMessage ...>, as the handler got it
    #   result.dispatched   # => [#<StoreMessage ...>], what the handler dispatched
    #   result.elements     # => ['<div id="messages">...</div>'], what it patched
    #   result.signals      # => { 'count' => 1 }
    #   result.errors       # => nil, or { text: 'must be present' } when rejected
    #
    # Each command is posted to the app's +/commands+, as a browser's form is:
    # its payload is encoded into a form's strings, decoded and validated by
    # the app, and handled by the app, which has the component installed. So
    # +before_command+, validation and +reject+ work as they do in the app.
    # Commands the handler dispatches are recorded instead of appended to the
    # store, so they don't run.
    class Harness
      # @return [Class<Sidereal::App>] the app the commands are handled in: a
      #   subclass of +app+, with the component installed
      attr_reader :app

      # @param component [#sidereal_install] the component, page or layout
      # @param app [Class<Sidereal::App>] the app to handle commands like, ex.
      #   the one the component is installed in, for its +before_command+ and
      #   helpers. It isn't changed.
      def initialize(component, app: Sidereal::App)
        recorder = @recorder = Recorder.new
        @app = Class.new(app) do
          install(component)

          define_method(:store) { recorder }
          private :store

          define_method(:before_command) do |cmd|
            recorder.command = super(cmd)
          end
          private :before_command

          define_method(:reject) do |errors|
            recorder.errors = errors
            super(errors)
          end
          private :reject
        end
      end

      # Handle a command, as if a browser had sent it.
      #
      #   harness.handle(SendMessage, { text: 'hi' })
      #   harness.handle(SendMessage.new(payload: { text: 'hi' }))
      #   harness.handle(SendMessage, form: { 'text' => '' })   # the strings a form posts
      #
      # @param command [Class<Sidereal::Message>, Sidereal::Message]
      # @param payload [Hash, nil] the payload, for a command class
      # @param form [Hash, nil] the payload as a form posts it, all Strings,
      #   instead of +payload+: to test what the app makes of a form's input
      # @param session [Hash] the request's session
      # @return [Result]
      def handle(command, payload = nil, form: nil, session: {})
        message =
          if !command.is_a?(Class) then command
          elsif payload then command.new(payload:)
          else command.new
          end
        form ||= form_for(message)
        fields = { 'type' => message.type, '_cid' => 'test' }
        fields['payload'] = form if form

        @recorder.reset
        env = Rack::MockRequest.env_for(
          '/commands', method: 'POST', params: { 'command' => fields },
          'HTTP_ACCEPT' => 'text/event-stream', 'HTTP_DATASTAR_REQUEST' => 'true'
        )
        env['rack.session'] = session
        status, headers, body = Sync { app.call(env) }

        Result.new(
          status:, headers:, body: read(body), command: @recorder.command,
          dispatched: @recorder.dispatched.dup, errors: @recorder.errors, session: env['rack.session']
        )
      end

      private

      # The payload as a form posts it: every attribute, blank where the
      # payload has no value, since a form posts its empty fields too.
      def form_for(message)
        encoded = app.forms_codec.encode_payload(message).value
        return encoded unless encoded.is_a?(Hash)

        message.class.payload_attribute_names.to_h { |name| [name.to_s, ''] }.merge(encoded)
      end

      def read(body)
        Sync do
          if body.respond_to?(:each)
            String.new.tap { |text| body.each { |chunk| text << chunk } }
          else
            # A Datastar response streams: it's called with the connection.
            StringIO.new.tap { |io| body.call(io) }.string
          end
        ensure
          body.close if body.respond_to?(:close)
        end
      end

      # The store the harness's app dispatches to: it keeps what it's given.
      class Recorder
        attr_reader :dispatched
        attr_accessor :command, :errors

        def initialize = reset

        def append(message)
          @dispatched << message
          true
        end

        def reset
          @command = nil
          @dispatched = []
          @errors = nil
        end
      end
      private_constant :Recorder
    end

    # One event of a Datastar response: its type, ex.
    # +"datastar-patch-elements"+, and its data, by key, ex.
    # +{ 'elements' => '<div id="x">...</div>', 'selector' => '#list' }+.
    Event = Data.define(:type, :data)

    # What handling a command did. See {Harness#handle}.
    #
    # @!attribute command
    #   @return [Sidereal::Message, nil] the command the handler was given:
    #     built by the app from the posted form, after its +before_command+.
    #     +nil+ if the form didn't decode
    # @!attribute dispatched
    #   @return [Array<Sidereal::Message>] the commands the handler dispatched
    # @!attribute errors
    #   @return [Hash{Symbol => String}, nil] the errors the command was
    #     rejected with, by attribute, or +nil+ if it wasn't
    # @!attribute session
    #   @return [Hash] the session, after the handler
    Result = Data.define(:status, :headers, :body, :command, :dispatched, :errors, :session) do
      # Whether the command was rejected, as invalid or by the handler.
      def rejected? = !errors.nil?

      # The Datastar events the response sent the browser, in order.
      #
      # @return [Array<Event>]
      def events
        body.split(/\n\n+/).filter_map do |block|
          type = nil
          data = {}
          block.each_line(chomp: true) do |line|
            field, value = line.split(': ', 2)
            if field == 'event'
              type = value
            elsif field == 'data'
              key, text = value.split(' ', 2)
              data[key] = data.key?(key) ? "#{data[key]}\n#{text}" : text.to_s
            end
          end
          Event.new(type:, data:) if type
        end
      end

      # The HTML the response patched into the page, in order. Scripts run
      # with +browser.execute_script+ are patched in too, as +<script>+
      # elements.
      #
      # @return [Array<String>]
      def elements = events_of('datastar-patch-elements').map { |event| event.data['elements'].to_s }

      # The signals the response patched, merged in order.
      #
      # @return [Hash{String => Object}]
      def signals
        events_of('datastar-patch-signals').reduce({}) do |signals, event|
          signals.merge(JSON.parse(event.data['signals']))
        end
      end

      private

      def events_of(type) = events.select { |event| event.type == type }
    end
  end
end
