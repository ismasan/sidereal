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

    # Installed by {.handle} when called without a block: dispatches the
    # validated command to the async store and returns +200+.
    DEFAULT_HANDLE_BLOCK = ->(cmd) {
      dispatch(cmd)
      status 200
    }

    class << self
      def inherited(subclass)
        super
        handled_commands.each do |type, klass|
          subclass.handled_commands[type] = klass
        end
      end

      # Registry of command classes this app exposes to the web via
      # +POST /commands+. Populated by {.handle}. Each subclass gets
      # its own copy (seeded from the superclass in {.inherited}), so
      # later +handle+ calls on a parent don't leak into children that
      # have already been defined.
      #
      # @return [Hash{String => Class<Sidereal::Message>}] type string → command class
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
        @commander ||= begin
          cls = Class.new(Commander)
          const_set(:Commander, cls)
          cls
        end
      end

      def commands(cmder = nil, &block)
        @commander = cmder if cmder
        @commander.class_eval(&block) if block_given?
        self
      end

      # Define the channel name used by this App's commander to publish
      # processed messages. Accepts either a static string or a block
      # that receives the message and returns a channel name.
      #
      # System notifications ({Sidereal::System::NotifyRetry} and
      # {NotifyFailure}) bypass the user-supplied resolver and instead
      # use the +:source_channel+ stamped into the notification's
      # +metadata+ by the dispatcher. This prevents user resolvers that
      # access domain-specific payload keys (e.g.
      # +msg.payload.fetch(:donation_id)+) from crashing on system
      # messages whose payload has a different shape.
      #
      # @example Static channel
      #   channel_name 'todos'
      # @example Dynamic channel
      #   channel_name { |msg| "todos.#{msg.payload.list_id}" }
      #
      # @return [self]
      def channel_name(static_value = nil, &block)
        user_fn = block || ->(_msg) { static_value }
        commander.define_singleton_method(:channel_name) do |msg|
          if msg.is_a?(Sidereal::System::Notification)
            msg.metadata[:source_channel] || 'system'
          else
            user_fn.call(msg)
          end
        end
        self
      end

      def command_helpers(...)
        commands(...)
      end

      def before_command(&block)
        define_method(:before_command, &block)
        private :before_command
      end

      # Register a command with the app's {Commander}, so the async
      # worker pipeline can process it. Commands registered only via
      # +command+ are *not* addressable from the browser — they are
      # internal workflow steps, dispatched from other handlers,
      # automations, or sagas.
      #
      # To expose a command to the web (+POST /commands+), register it
      # additionally with {.handle}.
      #
      # @see .handle for web exposure
      # @see Sidereal::Commander#command
      def command(...)
        commander.command(...)
        Sidereal.register(commander)
        self
      end

      def schedule(...)
        commander.schedule(...)
        Sidereal.register(commander)
        self
      end

      # Expose a command to the web (+POST /commands+) and register a
      # handler that runs synchronously during the HTTP request.
      #
      # Every call to +handle+ does two things:
      # 1. Adds the command class to the app's +handled_commands+
      #    registry. Types not in this registry return +404+ from
      #    +POST /commands+.
      # 2. Defines a handler method. If a block is given, it is the
      #    handler; otherwise {DEFAULT_HANDLE_BLOCK} is installed,
      #    which simply dispatches the command to the async store and
      #    returns +200+.
      #
      # +handle+ does **not** register the command with the async
      # {Commander}. If you want a web-submitted command to also be
      # processed by workers, register it separately with {.command}.
      # (The default handler's +dispatch+ will push it onto the store,
      # where a +command+ block can pick it up.)
      #
      # Inside a custom block you have access to:
      # - +browser+ — the SSE stream for pushing DOM updates (requires an SSE request)
      # - +dispatch(MessageClass, payload)+ — correlate and append a new command to the store
      # - +store+, +pubsub+, +params+, +session+ — the usual App instance helpers
      #
      # @param cmd_classes [Array<Class<Sidereal::Message>>] one or more command classes to expose
      # @yield [cmd] the handler block, executed in the App instance context
      # @yieldparam cmd [Sidereal::Message] the validated, metadata-enriched command
      # @return [self]
      #
      # @example Expose multiple commands with the default async-dispatch handler
      #   handle AddTodo, RemoveTodo
      #
      # @example Expose a single command with a paired async worker
      #   handle AddTodo
      #   command AddTodo do |cmd|
      #     TODOS[cmd.payload.todo_id] = cmd.payload
      #   end
      #
      # @example Custom handler that dispatches a follow-up command
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
      def handle(*cmd_classes, &block)
        cmd_classes.each do |cmd_class|
          handled_commands[cmd_class.type] = cmd_class
          method_name = Sidereal.message_method_name(HANDLE_METHOD_PREFIX, cmd_class.type)
          block ||= DEFAULT_HANDLE_BLOCK
          define_method(method_name, &block)
          private(method_name)
        end
        self
      end
    end

    get '/updates/:channel_name' do |channel_name:|
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
      cmd_class = self.class.handled_commands[payload[:type]]
      halt 404, 'unknown command' unless cmd_class
      cmd = cmd_class.new(payload)
      if cmd.valid?
        handle_local_command(cmd)
      else
        patch_command_errors(cmd.payload.errors)
      end
    end

    private def handle_local_command(cmd)
      method_name = Sidereal.message_method_name(HANDLE_METHOD_PREFIX, cmd.type)
      @__current_msg = before_command(cmd)
      send(method_name, @__current_msg)
    end

    # This dispatch is available to sync command handlers
    # @example
    #  handle SomeCommand do |cmd|
    #    dispatch cmd
    #  end
    private def dispatch(*args)
      cmd = case args
        in [Class => c, Hash => payload]
          c.new(payload:)
        in [Class => c]
          c.new
        in [MessageInterface => m]
          m
      end

      cmd = @__current_msg.correlate(cmd) if @__current_msg
      store.append(cmd)
    end

    def params
      @params ||= request.env.fetch('router.params', EMPTY_PARAMS)
    end

    def pubsub
      Sidereal.pubsub
    end

    private def store
      Sidereal.store
    end

    # The Datastar dispatcher for the current request. Supports both one-off
    # updates (+#patch_elements+, +#patch_signals+, +#execute_script+, etc.)
    # and multi-event streaming via +#stream { |sse| ... }+.
    #
    # Also aliased as {#browser} for readability inside handler blocks.
    def datastar
      @datastar ||= Datastar.new(request:, view_context: self, heartbeat: 0.4).on_error do |err|
        puts "Datastar error: #{err}"
        puts err.backtrace.join("\n")
      end
    end

    alias_method :browser, :datastar

    private def before_command(cmd)
      cmd
    end

    # Stream field-level validation errors back to the browser via SSE.
    #
    # For each error, patches the matching error-message element and adds
    # an +errors+ CSS class to the field wrapper. Expects the form to use
    # the {Components::Command} component, which generates the matching
    # element IDs from the command's +_cid+ value.
    #
    # Called automatically for invalid commands, but can also be used
    # directly inside a +handle+ block for custom validation logic.
    #
    # @param errors [Hash{Symbol => String}] field name to error message pairs
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
      datastar.stream(heartbeat: false) do |sse|
        errors.each do |field, error|
          field_id = [cid, field].join('-')
          sse.patch_elements Components::Command::ErrorMessages.new(field_id, error)
          wrapper_id = [field_id, 'wrapper'].join('-')
          sse.execute_script %(document.getElementById("#{wrapper_id}").classList.add('errors'))
        end
      end
    end
  end
end
