# frozen_string_literal: true

require 'datastar'
require 'datastar/async_executor'
require_relative 'request_helpers'
require_relative 'commander'

Datastar.configure do |config|
  config.compression = true
  config.executor = Datastar::AsyncExecutor.new
end

module Sidereal
  class App < Router
    include RequestHelpers

    def phlex(component)
      [200, { 'content-type' => 'text/html' }, [component.call(context: self)]]
    end

    class << self
      def inherited(subclass)
        super
        Sidereal.register(subclass)
      end

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

      def commander
        @commander ||= Class.new(Commander)
      end

      def before_command(&block)
        define_method(:before_command, &block)
        private :before_command
      end

      def command(...)
        commander.command(...)
      end
    end

    NO_CONTENT = [200, { 'Content-Type' => 'text/plain' }.freeze, [].freeze].freeze

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
      cmd = self.class.commander.from(payload)
      streaming_command_errors(cmd, datastar) do
        cmd = before_command(cmd.with_metadata(channel: channel_name))
        store.append(cmd)
        # commander.handle(cmd)
        NO_CONTENT
      end
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
        cid = datastar.request.params['command']['_cid']

        #[cid]-[name]-errors
        datastar.send(:stream_no_heartbeat) do |sse|
          cmd.payload.errors.each do |field, error|
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
