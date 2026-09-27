# frozen_string_literal: true

require 'monitor'
require 'tsort'

module Sidereal
  # A container of named dependencies whose values may depend on each other.
  #
  # Apps register their dependencies at load time (by convention in
  # +config/dependencies/*.rb+), and integrations register their own. A
  # dependency names the keys it needs, and its block builds the value from
  # theirs, in that order, so registrations can come in any order: nothing is
  # built until a value is asked for.
  #
  #   require 'sequel'
  #
  #   Sidereal.dependencies.register!('db', ['logger']) do |logger|
  #     logger.info 'Connecting to DB'
  #     Sequel.sqlite(ENV.fetch('DB_PATH'))
  #   end.teardown do |db|
  #     db.disconnect
  #   end
  #
  #   Sidereal.dependencies['db'] # builds 'logger' first
  #
  # Two lifecycles:
  #
  # - {#register!} — a singleton, built once per process and memoized.
  # - {#register} — transient: built on every {#[]}.
  #
  # {Sidereal::Host#start} calls {#build!} in every process before anything
  # else boots, so a fork-unsafe singleton (a database connection) is built per
  # worker, and a missing key or a cycle fails the boot. {Sidereal::Host#stop}
  # calls {#teardown}, dependents before their dependencies.
  #
  # Code to share between workers — +require+s — belongs outside the blocks,
  # where it runs as the file loads: in the process that forks the workers when
  # the host preloads the app. Values must not be built there, or every worker
  # would inherit them: that process calls {#forbid_builds!}, and a value used
  # in a process other than the one that built it raises {ForkError}.
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
    # A registration after {#build!}.
    class LockedError < Error; end
    # An override of a key whose value, or a value built from it, already
    # exists: whatever holds that value would keep the replaced one.
    class ResolvedDependencyError < Error; end
    # A build in the process that forks workers, or a value used in a process
    # other than the one that built it.
    class ForkError < Error; end

    # One registered dependency. Returned by {Dependencies#register!} and
    # {Dependencies#register} so a teardown can be chained on.
    class Registration
      attr_reader :key, :deps, :builder, :tearer

      def initialize(key, deps, builder, memoize:)
        @key = key
        @deps = deps
        @builder = builder
        @memoize = memoize
        @tearer = nil
      end

      def memoize? = @memoize

      # Set the block {Dependencies#teardown} runs with this dependency's
      # value. Only singletons have a value to tear down.
      #
      # @yieldparam value [Object] the built value
      # @return [self]
      def teardown(&block)
        raise ArgumentError, 'teardown requires a block' unless block
        unless memoize?
          raise ArgumentError,
                "'#{key}' is transient (registered with #register), so there is no instance to tear down. " \
                'Register it with #register! to give it a teardown.'
        end

        @tearer = block
        self
      end

      def to_s = deps.empty? ? key : "#{key}[#{deps.join(', ')}]"

      def inspect
        file, line = builder.source_location
        "#<#{self.class.name} #{memoize? ? 'register!' : 'register'} #{self}#{" at #{file}:#{line}" if file}>"
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
      # The process the values were built in.
      @values_pid = nil
      # The process that forks workers, where nothing may be built.
      @forbidden_pid = nil
      # Class name => keys it injects. Names rather than classes, so reloading
      # a class replaces its entry instead of retaining the old class.
      @injections = {}
      @built = false
      @monitor = Monitor.new
    end

    # Register a singleton: built once per process and memoized. {#build!}
    # builds every singleton; before that, the first {#[]} builds it.
    #
    # A key registers once. Pass +override: true+ to replace an existing
    # registration (or add it if absent) — how an integration swaps a default:
    #
    #   config.dependencies.register!('sidereal.store', override: true) do
    #     Sidereal::Store::FileSystem.new(root: 'storage/store')
    #   end
    #
    # An override is refused once the key has been resolved, or any singleton
    # built from it, since whoever holds that value would keep the old one.
    #
    # @param key [String, Symbol]
    # @param deps [Array<String, Symbol>] keys whose values the block receives, in order
    # @param override [Boolean] replace an existing registration instead of raising
    # @yield the dependencies' values; returns the value
    # @return [Registration] chain +.teardown { |value| ... }+ to release it at shutdown
    # @raise [DuplicateDependencyError] the key is registered and +override+ is false
    # @raise [ResolvedDependencyError] overriding a key already resolved
    # @raise [LockedError] after {#build!}
    def register!(key, deps = [], override: false, &builder)
      add(key, deps, builder, memoize: true, override:)
    end

    # Register a transient dependency: built on every {#[]}.
    #
    # @param (see #register!)
    # @return [Registration]
    def register(key, deps = [], override: false, &builder)
      add(key, deps, builder, memoize: false, override:)
    end

    # Resolve a dependency, building the ones it names first.
    #
    # @param key [String, Symbol]
    # @return [Object]
    # @raise [UnknownDependencyError, CircularDependencyError]
    # @raise [ForkError] in a process that called {#forbid_builds!}, or for
    #   values built in another process
    def [](key)
      key = key.to_s
      registration = @registrations.fetch(key) { raise UnknownDependencyError, "'#{key}' is not registered" }
      # build! checked the whole graph; until then, check what this key reaches.
      check!(key) unless @built
      return build(registration) unless registration.memoize?

      check_values_pid!
      @values.fetch(key) do
        @monitor.synchronize do
          @values.fetch(key) { store(key, build(registration)) }
        end
      end
    end

    # @param key [String, Symbol]
    def key?(key) = @registrations.key?(key.to_s)

    def built? = @built

    # Check the graph, build every singleton in dependency order, and lock the
    # container against further registration. Idempotent within a process.
    #
    # @return [self]
    # @raise [UnknownDependencyError] a dependency, or a key injected with
    #   {#args}, is not registered
    # @raise [CircularDependencyError]
    # @raise [ForkError] in a process that called {#forbid_builds!}, or when
    #   values were built in another process
    def build!
      @monitor.synchronize do
        return self if @built

        check_injections!
        each_strongly_connected_component { |component| check_component!(component) }
        check_values_pid!
        tsort_each { |key| self[key] if @registrations[key].memoize? }
        @built = true
      end
      self
    end

    # Run the teardown of every singleton built in this process, dependents
    # before their dependencies, and forget the values, so a later {#build!}
    # builds afresh. A teardown that raises is logged and the rest still run.
    # Idempotent.
    #
    # @return [self]
    def teardown
      @monitor.synchronize do
        # A value is stored only after the values it depends on, so the
        # reverse of insertion order puts dependents first.
        @values.keys.reverse_each do |key|
          value = @values.delete(key)
          tearer = @registrations[key].tearer
          next unless tearer

          begin
            tearer.call(value)
          rescue StandardError => e
            Console.error(self, "Tearing down dependency '#{key}' failed", exception: e)
          end
        end
        @values_pid = nil
        @built = false
      end
      self
    end

    # Refuse to build anything in the calling process. Called by a host in the
    # process that forks its workers, before it loads the app: whatever is
    # built there is inherited by every worker, and a connection or socket
    # shared across processes is corrupted. Child processes are unaffected.
    #
    # @return [self]
    def forbid_builds!
      @forbidden_pid = Process.pid
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
    # before its dependencies are registered; {#build!} checks they are. Every
    # other argument reaches the class's own +#initialize+ untouched.
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

    # Record that +klass+ injects +keys+, for {#build!} to check.
    # Called by {Injection#append_features}.
    #
    # @api private
    def injected(klass, keys)
      class_name = klass.name || klass.inspect
      @monitor.synchronize { @injections[class_name] = @injections.fetch(class_name, []) | keys }
    end

    private

    def add(key, deps, builder, memoize:, override:)
      raise ArgumentError, 'a dependency requires a block that builds it' unless builder

      key = key.to_s
      registration = Registration.new(key, Array(deps).map(&:to_s).freeze, builder, memoize:)
      @monitor.synchronize do
        raise LockedError, "Cannot register '#{key}': dependencies are already built" if @built

        if @registrations.key?(key)
          raise DuplicateDependencyError, "'#{key}' is already registered. Pass override: true to replace it" unless override

          if (holder = @values.each_key.find { |built| reaches?(built, key) })
            raise ResolvedDependencyError,
                  "Cannot override '#{key}': '#{holder}' has already been resolved. Override before first use"
          end
        end

        @registrations[key] = registration
      end
      registration
    end

    # Whether resolving +from+ resolves +target+, directly or through its dependencies.
    def reaches?(from, target, seen = {})
      return true if from == target
      return false if seen[from]

      seen[from] = true
      @registrations.fetch(from).deps.any? { |dep| @registrations.key?(dep) && reaches?(dep, target, seen) }
    end

    def build(registration)
      if @forbidden_pid == Process.pid
        raise ForkError,
              "Cannot build '#{registration.key}' in the process that forks workers: every worker would " \
              'inherit it. Resolve it after boot (in a dependency block, or at runtime), not while the app loads'
      end

      registration.builder.call(*registration.deps.map { |dep| self[dep] })
    end

    def store(key, value)
      @values_pid ||= Process.pid
      @values[key] = value
    end

    def check_values_pid!
      return if @values_pid.nil? || @values_pid == Process.pid

      raise ForkError,
            "Dependencies #{@values.keys.map { |k| "'#{k}'" }.join(', ')} were built in process #{@values_pid} " \
            "and inherited by process #{Process.pid}. Build them in each process, after the fork"
    end

    def check_injections!
      @injections.each do |class_name, keys|
        keys.each do |key|
          next if @registrations.key?(key)

          raise UnknownDependencyError, "#{class_name} injects '#{key}', which is not registered"
        end
      end
    end

    def inspect_state = @built ? '(built)' : '(open)'

    def inspect_entries = @registrations.values.map(&:to_s)

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
