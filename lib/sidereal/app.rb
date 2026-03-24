# frozen_string_literal: true

require 'datastar'
require_relative 'request_helpers'

module Sidereal
  class App < Router
    include RequestHelpers

    CMD_METHOD_PREFIX = '__cmd_'
    DEFAULT_CMD_HANDLER = ->(*_) {}

    def phlex(component)
      [200, { 'content-type' => 'text/html' }, [component.call(context: self)]]
    end

    class << self
      def page(pg, layout: BasicLayout, &block)
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
          phlex layout.new(page_class.load(params, self))
        end

        self
      end

      def command_registry
        @command_registry ||= {}
      end

      def command(*args, &block)
        cmd_class = case args
        in [Class => klass] if klass < Sidereal::Message
          klass
        else
          raise ArgumentError, "unknown arguments #{args.inspect}"
        end

        command_registry[cmd_class.name] = cmd_class
        method_name = Sidereal.message_method_name(CMD_METHOD_PREFIX, cmd_class.name)
        block ||= DEFAULT_CMD_HANDLER
        define_method(method_name, block)
        private(method_name)
        self
      end

      def before_command(&block)
        define_method(:before_command, &block)
        private :before_command
      end
    end

    NO_CONTENT = [200, { 'Content-Type' => 'text/plain' }.freeze, [].freeze].freeze

    get '/updates' do
      channel = pubsub.subscribe('system')

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
      cmd_class = self.class.command_registry.fetch(payload[:type])
      cmd = cmd_class.new(payload[:payload])
      streaming_command_errors(cmd, datastar) do
        cmd = before_command(cmd)
        handle_command(cmd)
        NO_CONTENT
      end
    end

    def params
      request.env.fetch('router.params', {})
    end

    def handle_command(cmd)
      method_name = Sidereal.message_method_name(CMD_METHOD_PREFIX, cmd.class.name)
      send(method_name, cmd)
      dispatched_events.slice(0..).each do |msg|
        pubsub.publish cmd.channel, msg
      end
      pubsub.publish cmd.channel, cmd
      # TODO: enqueue dispatched_commands
      # dispatched_commands.slice(0..).each do |c|
      #   c = before_command(c)
      #   handle_command(c)
      # end
    end

    def pubsub
      @pubsub ||= Sidereal::PubSub::Memory.instance
    end

    private def datastar
      @datastar ||= Datastar.new(request:, view_context: self, heartbeat: 0.4).on_error do |err|
        puts "Datastar error: #{err}"
        puts err.backtrace.join("\n")
      end
    end

    private def before_command(cmd)
      cmd.with(channel: channel_name)
    end

    private def channel_name = 'system'

    private def dispatch(msg)
      if self.class.command_registry[msg.class.name]
        dispatched_commands << msg
      else
        dispatched_events << msg
      end
      self
    end

    private def dispatched_commands
      @dispatched_commands ||= []
    end

    private def dispatched_events
      @dispatched_events ||= []
    end

    # A helper to handle commands in web controllers
    # and stream errors back to the UI.
    # UI forms are assumed to use the Sourced::UI::Components::Command component
    # which includes the expected input names and _cid value.
    # @example
    #   Sourced::UI.streaming_command_errors(cmd, datastar) do |cmd|
    #     Sourced::CCC.handle!(MyDecider, cmd)
    #   end
    #
    # @param cmd [Sourced::CCC::Command] the command to process
    # @param datastar [Datastar::Dispatcher] the datastar instance to stream errors to
    private def streaming_command_errors(cmd, datastar, &)
      if cmd.valid? # <== schedule valid command for processing
        yield cmd if block_given?
      else
        cid = datastar.request.params['command']['_cid']

        #[cid]-[name]-errors
        datastar.send(:stream_no_heartbeat) do |sse|
          cmd.errors.each do |field, error|
            # 'text', "can't be blank"
            field_id = [cid, field].join('-')
            sse.patch_elements Components::Command::ErrorMessages.new(field_id, error)
            wrapper_id = [field_id, 'wrapper'].join('-')
            sse.execute_script %(document.getElementById("#{wrapper_id}").classList.add('errors'))
          end
        end
      end
    end
  end
end
