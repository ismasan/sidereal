# frozen_string_literal: true

require 'phlex'
require 'securerandom'
require_relative 'datastar_helpers'

module Sidereal
  module Components
    class BaseComponent < Phlex::HTML
      BLANK_HASH = {}.freeze
      include DatastarHelpers

      # Fiber-local slot holding the machine that command forms rendered inside
      # {#with_machine} must be valid for. Fiber-local for the same reason as
      # {Page::RENDERING_KEY}.
      MACHINE_KEY = :__sidereal_rendering_machine__

      # The configuration of the machine set by the innermost {#with_machine}
      # in this fiber, or +nil+.
      #
      # @return [Sourced::Machine::Configuration, nil]
      def self.current_machine = Thread.current[MACHINE_KEY]

      # Render every instance of this component, and its subclasses, inside
      # {#with_machine}, with the machine +reader+ returns.
      #
      # @example
      #   class BookingPage < Sidereal::Page
      #     with_machine { @booking }
      #   end
      def self.with_machine(&reader)
        raise ArgumentError, 'with_machine needs a block returning the machine' unless reader

        @machine_reader = reader
      end

      def self.machine_reader
        @machine_reader || (superclass.machine_reader if superclass.respond_to?(:machine_reader))
      end

      # Declare a stylesheet this component needs, from a file or inline. It's
      # registered with an app's assets when the app installs the component,
      # with +component Chat+ (see {.sidereal_install}), and layouts link it. A relative +path+ is
      # relative to the file that calls this method: called from a helper
      # module, that's the helper's file, so pass it an absolute path.
      #
      #   class Chat < Sidereal::Components::BaseComponent
      #     stylesheet 'chat.css', path: 'chat.css'
      #   end
      #
      #   class ChatApp < Sidereal::App
      #     component Chat
      #   end
      #
      # @param name [String] its name in the app, ending in +.css+
      # @param path [String, Pathname, nil] the file
      # @param css [String, nil] its content
      # @return [Assets::Declaration]
      def self.stylesheet(name, path: nil, css: nil)
        declare_asset(name, :css, path && File.expand_path(path, File.dirname(caller_locations(1, 1).first.path)), css)
      end

      # Declare a script this component needs, from a file or inline. See
      # {.stylesheet}.
      #
      # @param name [String] its name in the app, ending in +.js+
      # @param path [String, Pathname, nil] the file
      # @param js [String, nil] its content
      # @return [Assets::Declaration]
      def self.javascript(name, path: nil, js: nil)
        declare_asset(name, :js, path && File.expand_path(path, File.dirname(caller_locations(1, 1).first.path)), js)
      end

      # Declare another file this component needs, such as an image, which it
      # links with {#asset_url}. See {.stylesheet}.
      #
      # @param name [String] its name in the app, with its extension
      # @param path [String, Pathname] the file
      # @return [Assets::Declaration]
      def self.file(name, path:)
        declare_asset(name, :file, File.expand_path(path, File.dirname(caller_locations(1, 1).first.path)), nil)
      end

      # Declare an inline stylesheet, named after the class and numbered:
      # UI::Chat's first is +ui/chat-1.css+, its second +ui/chat-2.css+.
      #
      #   class UI::Chat < Sidereal::Components::BaseComponent
      #     css <<~CSS
      #       .chat { border: 1px solid; }
      #     CSS
      #   end
      #
      # @param content [String]
      # @return [Assets::Declaration]
      # @raise [ArgumentError] for a class without a name
      def self.css(content) = declare_asset(inline_asset_name(:css), :css, nil, content)

      # Declare an inline script, named like {.css}'s: +ui/chat-1.js+.
      #
      # @param content [String]
      # @return [Assets::Declaration]
      # @raise [ArgumentError] for a class without a name
      def self.js(content) = declare_asset(inline_asset_name(:js), :js, nil, content)

      # The assets this component declares, after its superclass's.
      #
      # @return [Array<Assets::Declaration>]
      def self.assets
        inherited = superclass.respond_to?(:assets) ? superclass.assets : []
        inherited + (@assets || [])
      end

      # Register this component's {.assets} with +registry+. An asset already
      # registered, as by another component with the same superclass, is left
      # as it is. {App.page} calls it for a page and its layout, and
      # {App.layout} for a layout.
      #
      # @param registry [Assets]
      # @return [void]
      def self.register_assets(registry)
        assets.each { |asset| asset.register_in(registry) }
      end

      # Register this component's {.assets} with +app+'s: what {App.install}
      # calls.
      #
      # @param app [Class<Sidereal::App>]
      # @return [void]
      def self.sidereal_install(app) = register_assets(app.assets)

      def self.declare_asset(name, kind, path, content)
        Assets::Declaration.new(name:, kind:, path:, content:).tap { |asset| (@assets ||= []) << asset }
      end

      def self.inline_asset_name(kind)
        raise ArgumentError, "#{inspect} has no name to name its inline #{kind} after" unless name

        @inline_asset_counts ||= Hash.new(0)
        number = @inline_asset_counts[kind] += 1
        # The dash keeps Chat's 11th apart from Chat1's first.
        "#{name.split('::').map { |part| Utils.snake_case(part) }.join('/')}-#{number}.#{kind}"
      end

      private_class_method :declare_asset, :inline_asset_name

      private def around_template(&block)
        reader = self.class.machine_reader
        return super unless reader

        with_machine(instance_exec(&reader)) { super(&block) }
      end

      # Render the block with +machine+ as the current machine: a command form
      # rendered inside it, for a command the machine handles, raises
      # {Sidereal::CommandNotAvailableError} unless the machine accepts that
      # command in its current state. Forms for commands the machine doesn't
      # handle aren't checked. Restores the previous machine afterwards, so the
      # innermost one wins.
      #
      # @param machine [#to_machine_config] a Sourced::Machine, or a
      #   Sourced::Machine::Configuration
      private def with_machine(machine)
        configuration = machine.to_machine_config
        previous = Thread.current[MACHINE_KEY]
        Thread.current[MACHINE_KEY] = configuration
        begin
          yield
        ensure
          Thread.current[MACHINE_KEY] = previous
        end
      end

      private

      def params
        context.request.env.fetch('router.params', BLANK_HASH)
      end

      private def command(klass, *args, &block)
        render Sidereal::Components::Command.new(klass, *args, &block)
      end

      # The URL of one of the app's assets. See {Sidereal::App#asset_url}.
      #
      #   img(src: asset_url('logo.svg'))
      def asset_url(name) = context.asset_url(name)

      def dom_id(prefix)
        [prefix, SecureRandom.hex(4)].join('-')
      end
    end
  end
end
