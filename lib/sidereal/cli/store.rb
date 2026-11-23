# frozen_string_literal: true

require 'json'
require 'sidereal/cli'
require 'sidereal/integrations/file_system'

module Sidereal
  module CLI
    # `sid store`: the messages in the app's file system store — what's
    # waiting, scheduled, being handled and dead-lettered — and requeueing or
    # deleting them. Registered by {Sidereal::Integrations::FileSystem.setup},
    # and only offered while that integration's store is the app's.
    #
    # It works on the files directly, so it's safe to run while the app is
    # running: messages are moved by renames, as the app moves them. A message
    # can move on between being listed and acted on, and is then reported as
    # not found.
    class StoreCommand < Command
      # Not when an integration used after the file system one, ex. Sourced,
      # has replaced its store.
      def self.available? = Sidereal::Integrations::FileSystem.store?(Sidereal.config)

      # What every `sid store` command shares.
      module Helpers
        # A message on disk, with its JSON read: nil when the file isn't
        # valid JSON, so a corrupt file can still be listed and deleted.
        Item = Data.define(:entry, :message) do
          def id = message&.fetch('id', nil) || ''
          def type = message&.fetch('type', nil) || '(unreadable)'
        end

        # The app's file system store, with the app's components built.
        #
        # @return [Sidereal::Store::FileSystem]
        # @raise [Error] when another store has replaced it
        def store
          @store ||= begin
            CLI.boot_app!
            store = Sidereal.config['sidereal.store']
            unless store.is_a?(Sidereal::Store::FileSystem)
              raise Error, "The app's store is #{store.class}. `bin/sid store` works with " \
                           'the file system store (Sidereal.config.use_file_system!).'
            end

            store
          end
        end

        # The messages in +queues+, in queue order and earliest due first,
        # narrowed to +--type+ when given. A message that moved on while
        # being read is left out.
        #
        # @param queues [Array<Symbol>]
        # @return [Array<Item>]
        def items(queues)
          queues.flat_map do |queue|
            store.entries(queue).filter_map do |entry|
              message = begin
                store.read(entry) || next
              rescue JSON::ParserError
                nil
              end
              Item.new(entry, message)
            end
          end.select { |item| type_matches?(item.type) }
        end

        # The messages +refs+ name, each a message id, the start of one, or a
        # filename.
        #
        # @param refs [Array<String>]
        # @param queues [Array<Symbol>] where to look
        # @return [Array<Item>]
        # @raise [Error] for a ref that matches no message, or several
        def resolve!(refs, queues)
          candidates = items(queues)
          refs.map do |ref|
            name = File.basename(ref)
            matches = candidates.select { |item| item.entry.name == name || (!item.id.empty? && item.id.start_with?(ref)) }
            case matches.size
            when 1 then matches.first
            when 0 then raise Error, "No message #{ref} in #{queues.join(', ')}. See them with `bin/sid store list`."
            else
              raise Error, "#{ref} matches #{matches.size} messages; give more of the id:\n" +
                           matches.map { |item| "  #{item.id}  #{item.type}" }.join("\n")
            end
          end
        end

        # +--type+ is a message type, or a prefix ending in * for a namespace.
        def type_matches?(type)
          pattern = @options&.[](:type)
          return true unless pattern

          pattern.end_with?('*') ? type.start_with?(pattern.delete_suffix('*')) : type == pattern
        end

        # A span of time, to the largest whole unit: 45s, 12m, 3h, 2d.
        def duration(seconds)
          seconds = seconds.abs.to_i
          if seconds < 60 then "#{seconds}s"
          elsif seconds < 3600 then "#{seconds / 60}m"
          elsif seconds < 86_400 then "#{seconds / 3600}h"
          else "#{seconds / 86_400}d"
          end
        end

        def queue_list(value)
          return Sidereal::Store::FileSystem::QUEUES unless value

          value.split(',').map(&:strip).reject(&:empty?).map do |name|
            queue = name.to_sym
            unless Sidereal::Store::FileSystem::QUEUES.include?(queue)
              raise Error, "Unknown queue #{name}. Expected: #{Sidereal::Store::FileSystem::QUEUES.join(', ')}"
            end

            queue
          end
        end
      end

      # `sid store stats`
      class Stats < Command
        include Helpers

        self.description = 'Count the messages in each queue'

        HEADERS = ['Queue', 'Messages', 'Oldest', 'Next due'].freeze

        def call
          now = Time.now
          rows = Sidereal::Store::FileSystem::QUEUES.map do |queue|
            entries = store.entries(queue)
            oldest = entries.map(&:first_appended_at).min
            next_due = entries.map(&:not_before).min if queue == :scheduled
            [
              queue.to_s,
              entries.size.to_s,
              oldest ? duration(now - oldest) : '',
              next_due ? "in #{duration(next_due - now)}" : ''
            ]
          end
          Commands.print_table(terminal, HEADERS, rows, keep: 2, styles: { 0 => { 'dead' => :error } })
        end
      end

      # `sid store list [--queue Q,...] [--type T] [--limit N]`
      class List < Command
        include Helpers

        self.description = 'List the messages in the store, queue by queue'

        options do
          option '--queue <queues>', 'Only these queues, comma-separated: ready, scheduled, processing, dead'
          option '--type <type>', 'Only this message type; prefix.* matches a namespace'
          option '--limit <n>', 'How many to show (default 100)', type: Integer, default: 100
        end

        HEADERS = ['Id', 'Type', 'Queue', 'Attempt', 'Age', 'Notes'].freeze
        # Long enough for an exception's class and the start of its message.
        NOTE_WIDTH = 80

        def call
          raise Error, '--limit must be at least 1' if @options[:limit] < 1

          queues = queue_list(@options[:queue])
          found = items(queues)
          if found.empty?
            terminal.puts "No messages in #{queues.join(', ')}."
            return
          end

          shown = found.first(@options[:limit])
          now = Time.now
          rows = shown.map do |item|
            entry = item.entry
            [item.id, item.type, entry.queue.to_s, entry.attempt.to_s, duration(now - entry.first_appended_at),
             notes(item, now)]
          end
          Commands.print_table(terminal, HEADERS, rows, keep: 5, styles: { 2 => { 'dead' => :error } })
          # To stderr, so a pipe gets only the rows.
          if found.size > shown.size
            warn "Showing #{shown.size} of #{found.size}. Narrow with --queue or --type, or raise --limit."
          end
        end

        private

        def notes(item, now)
          entry = item.entry
          case entry.queue
          when :scheduled then "due in #{duration(entry.not_before - now)}"
          when :processing then "claimed by pid #{entry.claimed_by} #{duration(now - entry.claimed_at)} ago"
          when :dead
            failure = store.failure(entry)
            note = failure ? "#{failure['class']}: #{failure['message']}" : 'no error recorded'
            note.lines.first.to_s.chomp.then { |line| line.size > NOTE_WIDTH ? "#{line[0, NOTE_WIDTH - 1]}…" : line }
          else ''
          end
        end
      end

      # `sid store show REF [--json]`
      class Show < Command
        include Helpers

        self.description = 'Show a message: its payload, metadata, and why it failed if it did'

        one :ref, 'Message id (or its start) or filename, as `bin/sid store list` prints them', pattern: /\A[^-]/

        options do
          option '--json', 'Print the message, its place in the store and its error as JSON'
        end

        def call
          raise Error, 'Name a message, e.g. `bin/sid store show <id>`. `bin/sid store list` prints them.' unless @ref

          item = resolve!([@ref], Sidereal::Store::FileSystem::QUEUES).first
          entry = item.entry
          failure = store.failure(entry)

          if @options[:json]
            terminal.puts JSON.pretty_generate(
              queue: entry.queue, file: entry.name, attempt: entry.attempt,
              first_appended_at: entry.first_appended_at.utc.iso8601(6), not_before: entry.not_before.utc.iso8601(6),
              claimed_by: entry.claimed_by, claimed_at: entry.claimed_at&.utc&.iso8601(6),
              message: item.message, error: failure
            )
            return
          end

          print_entry(item)
          print_message(item.message) if item.message
          print_failure(failure) if failure
        end

        private

        def print_entry(item)
          entry = item.entry
          terminal.print_line :title, item.type, :reset, "  #{item.id}"
          field 'Queue', entry.queue.to_s, style: entry.queue == :dead ? :error : nil
          field 'Attempt', entry.attempt.to_s
          field 'Appended', entry.first_appended_at.utc.iso8601
          field 'Due', entry.not_before.utc.iso8601 if entry.queue == :scheduled
          field 'Claimed', "by pid #{entry.claimed_by} at #{entry.claimed_at.utc.iso8601}" if entry.queue == :processing
          field 'File', entry.path
        end

        def print_message(message)
          %w[created_at causation_id correlation_id].each do |key|
            field key.tr('_', ' ').capitalize, message[key].to_s if message[key]
          end
          section 'Payload', message['payload']
          section 'Metadata', message['metadata'] unless message['metadata'].nil? || message['metadata'].empty?
        end

        def print_failure(failure)
          terminal.puts
          terminal.puts 'Error', style: :title
          terminal.print_line :error, failure['class'].to_s, :reset, ": #{failure['message']}"
          Array(failure['backtrace']).each { |line| terminal.puts "  #{line}" }
        end

        def field(label, value, style: nil)
          terminal.print_line :key, label.ljust(16), *(style ? [style, value, :reset] : [value])
        end

        def section(title, value)
          terminal.puts
          terminal.puts title, style: :title
          terminal.puts JSON.pretty_generate(value)
        end
      end

      # `sid store requeue REF... | --all [--type T]`
      class Requeue < Command
        include Helpers

        self.description = 'Move dead letters back to ready, with a full set of retries'

        options do
          option '--all', 'Every dead letter (or every one of --type)'
          option '--type <type>', 'With --all, only this message type; prefix.* matches a namespace'
        end

        many :refs, 'Message ids (or their start) or filenames, as `bin/sid store list --queue dead` prints them'

        def call
          refs = @refs || []
          selected = if @options[:all]
                       raise Error, 'Give message ids or --all, not both' if refs.any?

                       items([:dead])
                     elsif refs.any?
                       resolve!(refs, [:dead])
                     else
                       raise Error, 'Name the dead letters to requeue, or pass --all. ' \
                                    '`bin/sid store list --queue dead` prints them.'
                     end
          return terminal.puts('No dead letters to requeue.') if selected.empty?

          selected.each do |item|
            store.requeue(item.entry.name)
            terminal.print_line :key, '  requeue  ', :reset, "#{item.id}  #{item.type}"
          rescue ArgumentError
            terminal.print_line :key, '  skip     ', :reset, "#{item.id}  #{item.type} (no longer dead)"
          end
        end
      end

      # `sid store delete REF... | --all [--type T]`
      class Delete < Command
        include Helpers

        self.description = 'Delete messages for good: dead letters, or ready and scheduled ones to cancel them'

        options do
          option '--all', 'Every dead letter (or every one of --type). Ready and scheduled messages are only deleted by id'
          option '--type <type>', 'With --all, only this message type; prefix.* matches a namespace'
        end

        many :refs, 'Message ids (or their start) or filenames, as `bin/sid store list` prints them'

        def call
          refs = @refs || []
          selected = if @options[:all]
                       raise Error, 'Give message ids or --all, not both' if refs.any?

                       items([:dead])
                     elsif refs.any?
                       resolve_deletable!(refs)
                     else
                       raise Error, 'Name the messages to delete, or pass --all for every dead letter.'
                     end
          return terminal.puts('No dead letters to delete.') if selected.empty?

          selected.each do |item|
            if store.delete(item.entry)
              terminal.print_line :key, '  delete  ', :reset, "#{item.id}  #{item.type}  (#{item.entry.queue})"
            else
              terminal.print_line :key, '  skip    ', :reset, "#{item.id}  #{item.type} (moved on before it was deleted)"
            end
          end
        end

        private

        # So a message being handled is refused by name, rather than reported
        # as missing.
        def resolve_deletable!(refs)
          resolve!(refs, Sidereal::Store::FileSystem::QUEUES).each do |item|
            if item.entry.queue == :processing
              raise Error, "#{item.id} is being handled right now, so it can't be deleted. Nothing was deleted."
            end
          end
        end
      end

      self.description = "Inspect the file system store's messages, and requeue or delete them"

      nested :command, {
        'stats' => Stats, 'list' => List, 'show' => Show, 'requeue' => Requeue, 'delete' => Delete
      }

      def call
        @command ? @command.call : print_usage
      end
    end
  end
end
