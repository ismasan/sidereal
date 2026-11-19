# frozen_string_literal: true

module Sidereal
  module Integrations
    module Sourced
      # Keeps the Sourced reactors among the classes a directory's files define
      # registered in a {::Sourced::Registry}, from what each scan of a
      # +from_dir+ source reports (see +Sourced::Component#on_dir_load+). The
      # integration subscribes one to {Sidereal.config} (see {Sourced.setup}),
      # so the scan that declares an app's +system/+ components, and each reload
      # of it, registers its reactors too.
      #
      #   sync = ReactorSync.new
      #   config.on_dir_load { |source, constants| sync.call(source, constants) }
      #
      # A constant is a reactor if it implements Sourced's reactor interface or
      # returns a group of reactors from +to_sourced_reactors+. Two kinds are
      # skipped:
      #
      # - Sidereal commanders, which the integration registers from
      #   {Sidereal.registry}.
      # - Reactors that handle no messages, ex. an abstract
      #   +ApplicationProjector < Sourced::Projector::StateStored+ that the
      #   app's projectors subclass.
      class ReactorSync
        # @param registry [::Sourced::Registry]
        # @param after_change [#call, nil] called after each scan has changed the
        #   registry, ex. to recompile a codec for reloaded message classes
        def initialize(registry: ::Sourced.registry, after_change: nil)
          @registry = registry
          @after_change = after_change
          @reactors = {} # by source: the reactors its last scan found
        end

        # @param source [Object] what scanned, ex. a +from_dir+ source
        # @return [Array<Module>] the reactors its last scan found
        def reactors(source) = @reactors.fetch(source, [])

        # In one batch, unregister the reactors +source+'s last scan found and
        # register the ones among +constants+. A reactor already registered, ex.
        # with +Sourced.register+, is skipped, but is the source's from now on:
        # its next scan replaces it. Then call +after_change+.
        # @param source [Object]
        # @param constants [Array<Object>] what the source's files define
        # @return [self]
        # @raise what registering raises (see {::Sourced::Registry#batch}), the
        #   registry left as it was. A registry listener that raises propagates
        #   too, with the change kept
        def call(source, constants)
          found = constants.select { |c| reactor?(c) }
          begin
            @registry.batch do
              reactors(source).each { |r| @registry.unregister(r) }
              found.each { |r| @registry.register(r) }
            end
          rescue StandardError, ScriptError
            # A registry listener that raises propagates with the change kept,
            # and the reactors found are this source's then too
            adopt(source, found) if found.any? { |r| @registry.registered?(r) }
            raise
          end
          adopt(source, found)
          self
        end

        private

        def adopt(source, found)
          @reactors[source] = found
          @after_change&.call
        end

        def reactor?(mod)
          return false unless mod.is_a?(Module)
          return false if mod.is_a?(Class) && mod <= Sidereal::Commander
          return false if mod.respond_to?(:handled_messages) && mod.handled_messages.empty?

          mod.respond_to?(:to_sourced_reactors) || ::Sourced::Config::ReactorInterface.resolve(mod).valid?
        end
      end
    end
  end
end
