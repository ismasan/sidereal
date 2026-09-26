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
      # first +keep+ are left out when every row is empty in them.
      def self.print_table(terminal, headers, rows, keep: headers.size)
        columns = headers.each_index.select do |i|
          i < keep || rows.any? { |row| !row[i].empty? }
        end
        widths = columns.map { |i| [headers[i], *rows.map { |row| row[i] }].map(&:size).max }
        line = lambda do |row|
          columns.each_with_index.map { |i, w| row[i].ljust(widths[w]) }.join('  ').rstrip
        end

        terminal.puts line.call(headers), style: :title
        rows.each { |row| terminal.puts line.call(row) }
      end

      # `sid commands list`
      class List < Command
        self.description = 'List the commands the app handles'

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
          Commands.print_table(terminal, HEADERS, rows)
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

          entry = Commands.catalog.entries.find do |e|
            Commands.display_name(e.command_class) == @class_name || e.type == @class_name
          end
          unless entry
            raise Error, "No command named #{@class_name.inspect}. Run `bin/sid commands list` to see them."
          end

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

      self.description = "Inspect the app's commands"

      nested :command, { 'list' => List, 'info' => Info }

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
