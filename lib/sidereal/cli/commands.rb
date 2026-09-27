# frozen_string_literal: true

require 'json'

module Sidereal
  module CLI
    # `sid commands`: inspect the app's commands. Only registered by an app's
    # bin/sid (see {CLI.load_app}).
    class Commands < Command
      # Every command the app knows about: those handled by Sidereal
      # commanders, by Sourced deciders, and those exposed to the web with
      # {Sidereal::App.handle}.
      class Catalog
        Entry = Data.define(:type, :command_class, :handlers, :web) do
          def web? = web
        end

        # @param apps [Array<Class>] Sidereal::App subclasses
        # @param commanders [Array<Class>] Sidereal::Commander classes
        # @param sourced_reactors [Array<Class>] reactors registered with
        #   Sourced. Those answering +handled_commands+ (deciders) are listed;
        #   Sidereal commanders among them are skipped, as +commanders+ has them.
        def initialize(apps:, commanders:, sourced_reactors: [])
          @apps = apps
          @commanders = commanders
          @sourced_reactors = sourced_reactors
        end

        # @return [Array<Entry>] sorted by command type
        def entries
          handlers = Hash.new { |hash, key| hash[key] = [] }
          @commanders.each do |commander|
            commander.handled_commands.each { |cmd| handlers[cmd] << commander }
          end
          sourced_deciders.each do |decider|
            decider.handled_commands.each { |cmd| handlers[cmd] << decider }
          end

          web = @apps.flat_map { |app| app.handled_commands.values }.uniq

          (handlers.keys | web)
            .map { |cmd| Entry.new(cmd.type, cmd, handlers[cmd].uniq, web.include?(cmd)) }
            .sort_by(&:type)
        end

        private

        def sourced_deciders
          @sourced_reactors.select do |reactor|
            reactor.respond_to?(:handled_commands) && !(reactor < Sidereal::Commander)
          end
        end
      end

      # The loaded app's command catalog. Call after {CLI.boot_app!}.
      #
      # @return [Catalog]
      def self.catalog
        Catalog.new(apps: app_classes, commanders: Sidereal.registry.commanders, sourced_reactors:)
      end

      def self.app_classes(klass = Sidereal::App)
        klass.subclasses.flat_map { |app| [app, *app_classes(app)] }
      end

      # Read without Sourced.router, which would set up the store just to ask.
      def self.sourced_reactors
        return [] unless defined?(::Sourced) && ::Sourced.respond_to?(:config)

        ::Sourced.config.router&.reactors || []
      end
      private_class_method :app_classes, :sourced_reactors

      # A class's name, or its inspect output for an anonymous class.
      def self.display_name(klass) = klass.name || klass.inspect

      # The catalog entry for a command, by class name or type.
      #
      # @param name [String] e.g. Greetings::SayHello or my_app.greetings.say_hello
      # @return [Catalog::Entry]
      # @raise [Error] when the app has no such command
      def self.find!(name)
        catalog.entries.find { |e| display_name(e.command_class) == name || e.type == name } ||
          raise(Error, "No command named #{name.inspect}. Run `bin/sid commands list` to see them.")
      end

      # Command line attributes (--name value) as a params hash for a
      # command's payload, before any type coercion: every value is a String,
      # as in a web form.
      #
      #   --units 2            {units: '2'}
      #   --units=2            {units: '2'}
      #   --gift               {gift: 'true'}, a flag without a value
      #   --address.city Paris {address: {city: 'Paris'}}
      #   --tags a --tags b    {tags: ['a', 'b']}, for an array attribute
      class Arguments
        # @param schema [Hash] the payload's JSON Schema
        def initialize(schema)
          @schema = schema
        end

        # @param tokens [Array<String>]
        # @return [Hash{Symbol => Object}]
        # @raise [Error] for a malformed or unknown attribute
        def parse(tokens)
          tokens = tokens.dup
          params = {}

          until tokens.empty?
            token = tokens.shift
            unless token.start_with?('--') && token.size > 2
              raise Error, "Expected an attribute like --name, got #{token.inspect}"
            end

            key, value = token.delete_prefix('--').split('=', 2)
            value ||= tokens.empty? || tokens.first.start_with?('--') ? 'true' : tokens.shift
            assign(params, key, value)
          end

          params
        end

        private

        def assign(params, key, value)
          *parents, leaf = key.split('.')
          target = params
          schema = @schema

          parents.each_with_index do |segment, depth|
            schema = property!(schema, segment, key, parents.first(depth))
            target = target[segment.to_sym] ||= {}
            raise Error, "--#{key} conflicts with an earlier attribute" unless target.is_a?(Hash)
          end

          property = property!(schema, leaf, key, parents)
          if property['type'] == 'array'
            (target[leaf.to_sym] ||= []) << value
          elsif target.key?(leaf.to_sym)
            raise Error, "--#{key} is given more than once"
          else
            target[leaf.to_sym] = value
          end
        end

        def property!(schema, segment, key, parents)
          properties = schema.fetch('properties', {})
          properties.fetch(segment) do
            known = properties.keys.map { |name| "--#{[*parents, name].join('.')}" }
            raise Error, "Unknown attribute --#{key}. " +
                         (known.any? ? "Expected: #{known.join(', ')}" : 'This command has no attributes.')
          end
        end
      end

      # A payload's JSON Schema as table rows: one per attribute, with nested
      # objects flattened to dotted names (address.city) and objects inside
      # arrays to name[].attribute.
      class SchemaTable
        HEADERS = ['Attribute', 'Type', 'Required', 'Default', 'Notes'].freeze
        # Keywords shown in their own column or as the type.
        SHOWN = %w[type properties required items anyOf oneOf default enum description].freeze

        # @param schema [Hash] a JSON Schema for an object
        def initialize(schema)
          @schema = schema
        end

        # @return [Array<Array<String>>] rows matching {HEADERS}
        def rows = object_rows(@schema)

        private

        def object_rows(schema, prefix = nil)
          required = schema.fetch('required', [])
          schema.fetch('properties', {}).flat_map do |name, property|
            path = prefix ? "#{prefix}.#{name}" : name
            row = [path, type_of(property), required.include?(name) ? 'yes' : '', default_of(property), notes_of(property)]
            [row, *nested_rows(property, path)]
          end
        end

        def nested_rows(property, path)
          if property['properties']
            object_rows(property, path)
          elsif property.dig('items', 'properties')
            object_rows(property['items'], "#{path}[]")
          else
            []
          end
        end

        def type_of(schema)
          if (variants = schema['anyOf'] || schema['oneOf'])
            types = variants.map { |variant| type_of(variant) }
            (types - ['null'] + (types & ['null'])).join(' | ')
          elsif schema['type'].is_a?(Array)
            schema['type'].join(' | ')
          elsif schema['type'] == 'array'
            schema['items'] ? "array of #{type_of(schema['items'])}" : 'array'
          else
            schema['type'] || 'any'
          end
        end

        def default_of(schema)
          schema.key?('default') ? JSON.generate(schema['default']) : ''
        end

        def notes_of(schema)
          notes = []
          notes << schema['description'] if schema['description']
          notes << "one of: #{schema['enum'].map { |value| JSON.generate(value) }.join(', ')}" if schema['enum']
          schema.each do |key, value|
            notes << "#{key}: #{JSON.generate(value)}" unless SHOWN.include?(key)
          end
          notes.join('; ')
        end
      end

      # Print rows as aligned columns under bold headers. Columns after the
      # first +keep+ are left out when every row is empty in them. +details+,
      # when given, holds a line per row, printed indented under it.
      def self.print_table(terminal, headers, rows, keep: headers.size, details: nil)
        columns = headers.each_index.select do |i|
          i < keep || rows.any? { |row| !row[i].empty? }
        end
        widths = columns.map { |i| [headers[i], *rows.map { |row| row[i] }].map(&:size).max }
        line = lambda do |row|
          columns.each_with_index.map { |i, w| row[i].ljust(widths[w]) }.join('  ').rstrip
        end

        terminal.puts line.call(headers), style: :title
        rows.each_with_index do |row, index|
          terminal.puts line.call(row)
          terminal.puts "  #{details[index]}" if details
        end
      end

      # `sid commands list [--schemas]`
      class List < Command
        self.description = 'List the commands the app handles'

        options do
          option '--schemas', "Add a line under each command with its payload's JSON Schema"
        end

        HEADERS = ['Command', 'Class', 'Handled by', 'Web'].freeze

        def call
          CLI.boot_app!

          entries = Commands.catalog.entries

          if entries.empty?
            terminal.puts 'No commands registered.'
            return
          end

          rows = entries.map do |entry|
            [
              entry.type,
              Commands.display_name(entry.command_class),
              entry.handlers.any? ? entry.handlers.map { |h| Commands.display_name(h) }.join(', ') : 'none',
              entry.web? ? 'yes' : ''
            ]
          end
          details = entries.map { |entry| JSON.generate(entry.command_class::Payload.to_json_schema) } if @options[:schemas]
          Commands.print_table(terminal, HEADERS, rows, details:)
        end
      end

      # `sid commands info NAME [--json]`
      class Info < Command
        self.description = "Show a command's payload schema"

        # Not `name`: Samovar::Command#name is the command's own name.
        one :class_name, 'Command class name or type, e.g. Greetings::SayHello', pattern: /\A[^-]/

        options do
          option '--json', 'Print the payload as JSON Schema'
        end

        def call
          raise Error, 'Name a command, e.g. `bin/sid commands info Greetings::SayHello`' unless @class_name

          CLI.boot_app!

          entry = Commands.find!(@class_name)
          schema = entry.command_class::Payload.to_json_schema
          if @options[:json]
            terminal.puts JSON.pretty_generate(schema)
            return
          end

          terminal.print_line :title, entry.type, :reset, "  #{Commands.display_name(entry.command_class)}"
          handlers = entry.handlers.map { |h| Commands.display_name(h) }
          terminal.print_line :key, 'Handled by  ', :reset, handlers.any? ? handlers.join(', ') : 'none'
          terminal.print_line :key, 'Web         ', :reset, entry.web? ? 'yes' : 'no'
          terminal.puts

          rows = SchemaTable.new(schema).rows
          if rows.empty?
            terminal.puts 'No payload attributes.'
          else
            Commands.print_table(terminal, SchemaTable::HEADERS, rows, keep: 3)
          end
        end
      end

      # `sid commands dispatch NAME --attribute value ...`
      class Dispatch < Command
        self.description = 'Send a command to the app, e.g. dispatch Greetings::SayHello --name Ada'

        # Not `name`: Samovar::Command#name is the command's own name.
        one :class_name, 'Command class name or type', pattern: /\A[^-]/
        many :attributes, 'Payload attributes as --name value. `dispatch --help` for more', stop: nil

        HELP = %w[-h --help].freeze

        # Printed after the usage by `dispatch --help`.
        ATTRIBUTES_HELP = <<~TEXT

          Attributes follow the command's payload (see `bin/sid commands info NAME --json`).
          Values are converted to the payload's types, as form fields from the web are.

            --units 2, --units=2      units: 2
            --gift                    gift: true, a flag without a value
            --address.city Paris      address: {city: "Paris"}
            --tags a --tags b         tags: ["a", "b"], for an array attribute

          The command is validated first: if anything is invalid, nothing is dispatched
          and every error is listed.
        TEXT

        # A codec registry holding a single command class.
        OneCommand = Data.define(:command_class) do
          def all(&) = [command_class].each(&)

          def [](type)
            command_class if type == command_class.type
          end
        end

        def call
          attributes = @attributes || []
          if (attributes & HELP).any?
            print_usage
            output.puts ATTRIBUTES_HELP
            return
          end
          raise Error, 'Name a command, e.g. `bin/sid commands dispatch Greetings::SayHello --name Ada`' unless @class_name

          CLI.boot_app!

          entry = Commands.find!(@class_name)
          if entry.handlers.empty?
            raise Error, "Nothing handles #{entry.type}, so it would never run. Run `bin/sid commands list` to see handlers."
          end

          command_class = entry.command_class
          params = Arguments.new(command_class::Payload.to_json_schema).parse(attributes)
          result = forms_codec(command_class).resolve(command_class.type, params)
          unless result.valid?
            lines = error_lines(result.errors, params).map { |line| "  #{line}" }
            raise Error, ["Not dispatched. Invalid attributes for #{entry.type}:", *lines].join("\n")
          end

          command = command_class.new(payload: result.value)
          Sidereal.dispatch!(command)

          terminal.print_line :title, 'Dispatched ', :reset, "#{entry.type}  #{Commands.display_name(command_class)}"
          terminal.print_line :key, 'id  ', :reset, command.id.to_s
          command.payload.to_h.each do |key, value|
            terminal.print_line :key, "  #{key}  ", :reset, value.inspect
          end
        end

        private

        # A forms codec for this one command. Commands the web accepts already
        # have one (App.forms_codec), but any command can be dispatched here,
        # so build it on the spot.
        def forms_codec(command_class)
          Sidereal::FormsCodec.new(registry: OneCommand.new(command_class)).compile!
        end

        # {attribute => message}, nested for nested attributes, as --path: message.
        # An attribute missing from the command line is reported as required,
        # rather than as a type mismatch against nothing.
        def error_lines(errors, params, prefix = nil)
          errors.flat_map do |key, message|
            path = prefix ? "#{prefix}.#{key}" : key.to_s
            given = params.is_a?(Hash) && params.key?(key.to_sym)
            if !given
              "--#{path}: is required"
            elsif message.is_a?(Hash)
              error_lines(message, params[key.to_sym], path)
            else
              "--#{path}: #{Array(message).join(', ')}"
            end
          end
        end
      end

      self.description = "Inspect and send the app's commands"

      nested :command, { 'list' => List, 'info' => Info, 'dispatch' => Dispatch }

      def call
        if @command
          @command.call
        else
          print_usage
        end
      end
    end
  end
end
