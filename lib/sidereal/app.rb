# frozen_string_literal: true

require 'datastar'
require 'datastar/async_executor'
require_relative 'commander'
require_relative 'components/basic_layout'

Datastar.configure do |config|
  config.compression = true
  config.executor = Datastar::AsyncExecutor.new
end

module Sidereal
  class App < Router
    HANDLE_METHOD_PREFIX = '__handle_'

    DEFAULT_HANDLE_BLOCK = ->(cmd) {
      dispatch(cmd)
      status 200
    }

    class << self
      def inherited(subclass)
        super
        Sidereal.register(subclass)
        handled_commands.each do |type, klass|
          subclass.handled_commands[type] = klass
        end
      end

      def handled_commands
        @handled_commands ||= {}
      end

      def layout(ly = nil)
        @layout = ly if ly
        @layout || BasicLayout
      end

      def page(pg, layout: nil, &block)
        layout ||= self.layout

        page_class = case pg
        in String => path if block_given?
          pagek = Class.new(Page, &block)
          pagek.path(path)
          pagek
        in Class => pagek if pagek < Page
          pagek
        else
          raise ArgumentError, "unknown arguments #{args.inspect}"
        end

        Sidereal::Page.register(page_class)
        get(page_class.path) do
          component layout.new(page_class.load(params, self))
        end

        self
      end

      def commander
        @commander ||= Class.new(Commander)
      end

      def commands(cmder = nil, &block)
        @commander = cmder if cmder
        @commander.class_eval(&block) if block_given?
        self
      end

      def command_helpers(...)
        commands(...)
      end

      def before_command(&block)
        define_method(:before_command, &block)
        private :before_command
      end

      def command(...)
        commander.command(...)
      end

      # Register a handler block that processes a command synchronously
      # during the HTTP request, instead of appending it to the async
      # store/worker pipeline.
      #
      # Inside the block you have access to:
      # - +browser+ — the SSE stream for pushing DOM updates (requires an SSE request)
      # - +dispatch(MessageClass, payload)+ — correlate and append a new command to the store
      # - +store+, +pubsub+, +params+, +session+ — the usual App instance helpers
      #
      # Commands without a registered +handle+ block fall through to the
      # default async path (+store.append+).
      #
      # @param cmd_class [Class<Sidereal::Message>] the command class to handle
      # @yield [cmd] the handler block, executed in the App instance context
      # @yieldparam cmd [Sidereal::Message] the validated, metadata-enriched command
      # @return [self]
      #
      # @example Basic handler that dispatches a follow-up command
      #   handle AddTodo do |cmd|
      #     TODOS[cmd.id] = cmd.payload.to_h
      #     dispatch NotifyUser, text: "Todo added: #{cmd.payload.title}"
      #     status 200
      #   end
      #
      # @example Streaming DOM updates back to the browser via SSE
      #   handle AddTodo do |cmd|
      #     TODOS[cmd.id] = cmd.payload.to_h
      #     browser.patch_elements TodoList.new(TODOS.values)
      #     browser.execute_script %(document.querySelector('.flash').textContent = 'Saved!')
      #   end
      def handle(cmd_class, &block)
        handled_commands[cmd_class.type] = cmd_class
        method_name = Sidereal.message_method_name(HANDLE_METHOD_PREFIX, cmd_class.type)
        block ||= DEFAULT_HANDLE_BLOCK
        define_method(method_name, &block)
        private(method_name)
        self
      end
    end

    get '/updates' do
      channel = pubsub.subscribe(channel_name)

      datastar.on_client_disconnect do |*args|
        Console.info 'client disconnect'
        channel.stop
      end.on_server_disconnect do |*args|
        Console.info 'server disconnect'
        channel.stop
      end.on_error do |ex|
        Console.info "ERROR #{ex}"
        channel.stop
      end

      datastar.stream do |sse|
        Console.info 'client connect'
        Sidereal::Page.subscribe(channel, sse, self)
      end
    end

    post '/commands' do
      payload = Types::SymbolizedHash.parse(request.params['command'])
      halt 404, 'unknown command' unless self.class.handled_commands.key?(payload[:type])
      cmd = Sidereal::Message.from(payload)
      streaming_command_errors(cmd, datastar) do
        handle_local_command(cmd)
      end
    end

    private def handle_local_command(cmd)
      method_name = Sidereal.message_method_name(HANDLE_METHOD_PREFIX, cmd.type)
      @__current_msg = before_command(cmd.with_metadata(channel: channel_name))
      with_streaming_sse do
        send(method_name, @__current_msg)
      end
    end

    private def dispatch(*args)
      cmd = case args
        in [Class => c, Hash => payload]
          @__current_msg.correlate(c.new(payload:))
        in [Class => c]
          @__current_msg.correlate(c.new)
        in [MessageInterface => m]
          m
      end

      store.append(cmd)
    end

    def params
      request.env.fetch('router.params', {})
    end

    def pubsub
      Sidereal.pubsub
    end

    private def store
      Sidereal.store
    end

    private def datastar
      @datastar ||= Datastar.new(request:, view_context: self, heartbeat: 0.4).on_error do |err|
        puts "Datastar error: #{err}"
        puts err.backtrace.join("\n")
      end
    end

    private def before_command(cmd)
      cmd
    end

    private def channel_name = 'system'

    attr_reader :browser

    NonStreamingConnection = Class.new(StandardError)

    class NonStreamingBrowser < BasicObject
      def respond_to?(...) = true

      def method_missing(m, *_args)
        ::Kernel.raise NonStreamingConnection, "Can't use ##{m}. Using `browser` object in a non-streaming, non-SSE connection"
      end
    end

    private def with_streaming_sse(&block)
      return yield if @browser

      if !datastar.sse?
        @browser = NonStreamingBrowser.new
        return yield
      end

      datastar.stream(heartbeat: false) do |sse|
        @browser = sse
        yield
      end
    end

    # A helper to handle commands in web controllers
    # and stream errors back to the UI.
    # UI forms are assumed to use the Sourced::UI::Components::Command component
    # which includes the expected input names and _cid value.
    # @example
    #   streaming_command_errors(cmd, datastar) do |cmd|
    #     dispatch(cmd)
    #   end
    #
    # @param cmd [Sidereal::Message] the command to process
    # @param datastar [Datastar::Dispatcher] the datastar instance to stream errors to
    private def streaming_command_errors(cmd, datastar, &)
      if cmd.valid? # <== schedule valid command for processing
        yield cmd if block_given?
      else
        patch_command_errors(cmd.payload.errors)
      end
    end

    # Stream field-level validation errors back to the browser via SSE.
    #
    # For each error, patches the matching error-message element and adds
    # an +errors+ CSS class to the field wrapper. Expects the form to use
    # the {Components::Command} component, which generates the matching
    # element IDs from the command's +_cid+ value.
    #
    # This is called automatically by +streaming_command_errors+ for
    # invalid commands, but can also be used directly inside a +handle+
    # block for custom validation logic.
    #
    # @param errors [Hash{Symbol => String}] field name to error message pairs
    # @return [void]
    #
    # @example Custom validation in a handle block
    #   handle PlaceOrder do |cmd|
    #     errors = validate_stock(cmd.payload)
    #     if errors.any?
    #       patch_command_errors(errors)
    #     else
    #       dispatch ConfirmOrder, order_id: cmd.payload.order_id
    #       browser.patch_elements OrderConfirmation.new(cmd.payload)
    #     end
    #   end
    private def patch_command_errors(errors)
      cid = datastar.request.params['command']['_cid']

      #[cid]-[name]-errors
      with_streaming_sse do
        errors.each do |field, error|
          # 'text', "can't be blank"
          field_id = [cid, field].join('-')
          browser.patch_elements Components::Command::ErrorMessages.new(field_id, error)
          wrapper_id = [field_id, 'wrapper'].join('-')
          browser.execute_script %(document.getElementById("#{wrapper_id}").classList.add('errors'))
        end
      end
    end
  end
end
