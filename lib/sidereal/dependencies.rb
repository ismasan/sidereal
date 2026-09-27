# frozen_string_literal: true

require 'monitor'
require 'tsort'

module Sidereal
  # A container of named dependencies whose factories may depend on each other.
  #
  # Apps register their dependencies at load time (by convention in
  # +config/dependencies/*.rb+), and integrations register their own. A
  # dependency names the keys it needs, and its factory receives their values
  # in that order, so registrations can come in any order: nothing is resolved
  # until a value is asked for, and {#finalize!} checks the whole graph at boot.
  #
  #   Sidereal.dependencies.register!('db') do
  #     Sequel.sqlite(ENV.fetch('DB_PATH'))
  #   end.stop do |db|
  #     db.disconnect
  #   end
  #
  #   Sidereal.dependencies.register!('sourced.store', ['db']) do |db|
  #     Sourced::Store.new(db)
  #   end
  #
  #   Sidereal.dependencies['sourced.store'] # builds 'db' first
  #
  # Two lifecycles:
  #
  # - {#register!} — a singleton, built once and memoized. {#finalize!} builds
  #   every singleton at boot; before that, the first {#[]} builds it.
  # - {#register} — transient: the factory runs on every {#[]}.
  #
  # {Sidereal::Host#start} calls {#finalize!} in every process before anything
  # else boots, so a fork-unsafe singleton (a database connection) is built
  # per worker, and a missing key or a cycle fails the boot. {Sidereal::Host#stop}
  # calls {#stop}, which runs each built singleton's stop callback, dependents
  # before their dependencies.
  #
  # {#args} builds a module that injects dependencies into a class's
  # +#initialize+ as keyword arguments defaulting to their values here.
  class Dependencies
    include TSort

    class Error < Sidereal::Error; end
    # A key that is not registered, asked for directly, named as a dependency,
    # or injected with {#args}.
    class UnknownDependencyError < Error; end
    # Dependencies that depend on each other, directly or through others.
    class CircularDependencyError < Error; end
    class DuplicateDependencyError < Error; end
    # A registration after {#finalize!}.
    class LockedError < Error; end

    NOOP_STOP = proc { |_value| }

    # One registered dependency. Returned by {Dependencies#register} and
    # {Dependencies#register!} so a stop callback can be chained on.
    class Registration
      attr_reader :key, :deps, :factory, :stopper

      def initialize(key, deps, factory, memoize:)
        @key = key
        @deps = deps
        @factory = factory
        @memoize = memoize
        @stopper = NOOP_STOP
      end

      def memoize? = @memoize

      # Set the callback {Dependencies#stop} runs with this dependency's value.
      # Only singletons have a value to stop.
      #
      # @yieldparam value [Object] the built value
      # @return [self]
      def stop(&block)
        raise ArgumentError, 'stop requires a block' unless block
        unless memoize?
          raise ArgumentError,
                "'#{key}' is transient (registered with #register), so there is no instance to stop. " \
                'Register it with #register! to give it a stop callback.'
        end

        @stopper = block
        self
      end

      # The registration as the call that made it, e.g.
      # +register!("sourced.store", ["db"]).stop+.
      #
      # @return [String]
      def to_s
        call = +"#{memoize? ? 'register!' : 'register'}(#{key.inspect}"
        call << ", #{deps.inspect}" unless deps.empty?
        call << ')'
        call << '.stop' unless stopper.equal?(NOOP_STOP)
        call
      end

      def inspect
        file, line = factory.source_location
        "#<#{self.class.name} #{self}#{" at #{file}:#{line}" if file}>"
      end
    end

    # The module {Dependencies#args} returns. Including it prepends it instead
    # (see {#append_features}), so its +#initialize+ runs before the class's own
    # whether or not that one calls +super+: it takes its keyword arguments,
    # assigns them, and passes everything else on. Each call to
    # {Dependencies#args} is a module of its own, so several includes chain.
    class Injection < Module
      IDENTIFIER = /\A[a-z_][a-zA-Z0-9_]*\z/

      # @return [Hash{Symbol => String}] keyword argument => dependency key
      attr_reader :names

      # @param container [Dependencies] resolves the defaults
      # @param names [Hash{Symbol => String}] keyword argument => dependency key
      def initialize(container, names)
        super()
        @container = container
        @names = names.freeze
        const_set(:CONTAINER, container)
        # Evaluated as a string so each dependency is a real keyword argument
        # with a default, visible to #parameters and to ArgumentError messages.
        # CONTAINER resolves lexically, against this module.
        params = names.map { |name, key| "#{name}: CONTAINER[#{key.inspect}]" }.join(', ')
        assigns = names.keys.map { |name| "@#{name} = #{name}" }.join('; ')
        module_eval <<~RUBY, __FILE__, __LINE__ + 1
          def initialize(*args, #{params}, **kwargs, &block)
            #{assigns}
            super(*args, **kwargs, &block)
          end
        RUBY
        attr_reader(*names.keys)
      end

      def append_features(base)
        @container.injected(base, @names.values)
        base.prepend(self)
        true
      end

      def inspect = "#<#{self.class.name} #{@names.map { |name, key| "#{name}: #{key.inspect}" }.join(', ')}>"
    end

    def initialize
      @registrations = {}
      @values = {}
      # Class name => keys it injects. Names rather than classes, so reloading
      # a class replaces its entry instead of retaining the old class.
      @injections = {}
      @finalized = false
      @monitor = Monitor.new
    end

    # Register a singleton: built once, memoized, and built at boot by {#finalize!}.
    #
    # @param key [String, Symbol]
    # @param deps [Array<String, Symbol>] keys whose values the factory receives, in order
    # @yield the factory
    # @return [Registration] chain +.stop { |value| ... }+ to add a stop callback
    def register!(key, deps = [], &factory)
      add(key, deps, factory, memoize: true)
    end

    # Register a transient dependency: the factory runs on every {#[]}.
    #
    # @param (see #register!)
    # @return [Registration]
    def register(key, deps = [], &factory)
      add(key, deps, factory, memoize: false)
    end

    # Resolve a dependency, resolving the ones it names first.
    #
    # @param key [String, Symbol]
    # @return [Object]
    # @raise [UnknownDependencyError, CircularDependencyError]
    def [](key)
      key = key.to_s
      registration = @registrations.fetch(key) { raise UnknownDependencyError, "'#{key}' is not registered" }
      # Finalizing checked the whole graph; until then, check what this key reaches.
      check!(key) unless @finalized
      return build(registration) unless registration.memoize?

      @values.fetch(key) do
        @monitor.synchronize do
          @values.fetch(key) { @values[key] = build(registration) }
        end
      end
    end

    # @param key [String, Symbol]
    def key?(key) = @registrations.key?(key.to_s)

    def finalized? = @finalized

    # Check the graph, build every singleton in dependency order, and lock the
    # container against further registration. Idempotent.
    #
    # @return [self]
    # @raise [UnknownDependencyError] a dependency, or a key injected with
    #   {#args}, is not registered
    # @raise [CircularDependencyError]
    def finalize!
      @monitor.synchronize do
        return self if @finalized

        @injections.each do |class_name, keys|
          keys.each do |key|
            next if @registrations.key?(key)

            raise UnknownDependencyError, "#{class_name} injects '#{key}', which is not registered"
          end
        end
        each_strongly_connected_component { |component| check_component!(component) }
        tsort_each { |key| self[key] if @registrations[key].memoize? }
        @finalized = true
      end
      self
    end

    # Run the stop callback of every singleton that has been built, dependents
    # before their dependencies, and forget the values. A callback that raises
    # is logged and the rest still run. Idempotent.
    #
    # @return [self]
    def stop
      @monitor.synchronize do
        # A value is stored only after the values it depends on, so the
        # reverse of insertion order puts dependents first.
        @values.keys.reverse_each do |key|
          value = @values.delete(key)
          begin
            @registrations[key].stopper.call(value)
          rescue StandardError => e
            Console.error(self, "Stopping dependency '#{key}' failed", exception: e)
          end
        end
      end
      self
    end

    # A module that injects dependencies into a class's +#initialize+ as keyword
    # arguments, with a reader for each. The keyword is the last segment of the
    # key (+'sourced.store'+ becomes +store:+) unless a Hash gives it one.
    #
    #   class CampaignsProjector < Sourced::Projector::StateStored
    #     include Sidereal.dependencies.args('db', 'sourced.store' => 'st')
    #   end
    #
    #   CampaignsProjector.new(partition_values)       # db and st from the container
    #   CampaignsProjector.new(partition_values, db:)  # db given, st from the container
    #
    # Defaults are resolved on each instantiation, so a class can include this
    # before its dependencies are registered; {#finalize!} checks they are.
    # Every other argument reaches the class's own +#initialize+ untouched.
    #
    # @param specs [Array<String, Symbol, Hash{String => String, Symbol}>]
    # @return [Injection]
    # @raise [ArgumentError] a keyword is not a valid identifier, or two keys
    #   map to the same keyword
    def args(*specs)
      names = specs.each_with_object({}) do |spec, acc|
        pairs = spec.is_a?(Hash) ? spec : { spec => spec.to_s.split('.').last }
        pairs.each do |key, name|
          name = name.to_s
          unless name.match?(Injection::IDENTIFIER)
            raise ArgumentError, "'#{name}' (for '#{key}') is not a valid keyword argument. Alias it: args('#{key}' => 'name')"
          end
          if acc.key?(name.to_sym)
            raise ArgumentError, "'#{key}' and '#{acc[name.to_sym]}' both inject as '#{name}'. Alias one: args('#{key}' => 'name')"
          end

          acc[name.to_sym] = key.to_s
        end
      end
      raise ArgumentError, 'args requires at least one dependency' if names.empty?

      Injection.new(self, names)
    end

    # Each dependency's key, followed by the keys it depends on:
    #
    #   #<Sidereal::Dependencies (open) dispatcher[db, logger] logger[printer] printer>
    def inspect
      "#<#{self.class.name} #{inspect_state}#{" #{inspect_entries.join(' ')}" unless @registrations.empty?}>"
    end

    # For pp and IRB: one dependency per line when they do not fit on one.
    def pretty_print(q)
      q.group(2, "#<#{self.class.name} #{inspect_state}", '>') do
        inspect_entries.each do |entry|
          q.breakable
          q.text entry
        end
      end
    end

    # Record that +klass+ injects +keys+, for {#finalize!} to check.
    # Called by {Injection#append_features}.
    #
    # @api private
    def injected(klass, keys)
      class_name = klass.name || klass.inspect
      @monitor.synchronize { @injections[class_name] = @injections.fetch(class_name, []) | keys }
    end

    private

    def add(key, deps, factory, memoize:)
      raise ArgumentError, 'a dependency requires a factory block' unless factory

      key = key.to_s
      registration = Registration.new(key, Array(deps).map(&:to_s).freeze, factory, memoize:)
      @monitor.synchronize do
        raise LockedError, "Cannot register '#{key}': dependencies are finalized" if @finalized
        raise DuplicateDependencyError, "'#{key}' is already registered" if @registrations.key?(key)

        @registrations[key] = registration
      end
      registration
    end

    def inspect_state = @finalized ? '(finalized)' : '(open)'

    def inspect_entries
      @registrations.values.map { |r| r.deps.empty? ? r.key : "#{r.key}[#{r.deps.join(', ')}]" }
    end

    def build(registration)
      registration.factory.call(*registration.deps.map { |dep| self[dep] })
    end

    def check!(key)
      each_strongly_connected_component_from(key) { |component| check_component!(component) }
    end

    def check_component!(component)
      return if component.size == 1 && !@registrations[component.first].deps.include?(component.first)

      raise CircularDependencyError, "Circular dependency between #{component.map { |k| "'#{k}'" }.join(', ')}"
    end

    def tsort_each_node(&) = @registrations.each_key(&)

    def tsort_each_child(key)
      @registrations.fetch(key).deps.each do |dep|
        raise UnknownDependencyError, "'#{key}' depends on '#{dep}', which is not registered" unless @registrations.key?(dep)

        yield dep
      end
    end
  end
end
