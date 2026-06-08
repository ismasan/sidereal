# frozen_string_literal: true

# Simple fiber- and thread-safe IoC container
# Example
#
# DEPS = IOCContainer.new
# # db singleton is lazily initialized if needed
# DEPS.register(:db) do
#   require 'sequel'
#   Sequel.connect ENV.fetch('DATABASE_URL')
# end
# database-backed repo depends on :db
# DEPS.register(:db_repo) do
#   DBRepo.new(DEPS.get(:db))
# end
# in-memory repo does not depend on :db
# DEPS.register(:mem_repo) do
#   MemRepo.new
# end
# # abstract repo will initialize either :db_repo or :mem_repo
# # depending on configuration
# DEPS.register(:repo) do
#   DEPS.get(ENV.fetch(:repo_type, :mem_repo).to_sym)
# end
#
# # App will :resolve what it needs from DEPS
# # only used dependencies will be initialized
# app = SomeApp.new(repo: DEPS[:repo])
#
# # Or wire dependencies straight into a class's constructor with #inject.
# # `.new` fills declared kwargs from the container; callers can still override.
# class SomeApp
#   include DEPS.inject(:repo)
# end
# SomeApp.new            # repo resolved from DEPS
# SomeApp.new(repo: x)   # caller wins
# # Separate includes accumulate (and are inherited), so framework classes can
# # ship dependencies that apps add to or override. See #inject.
#
# Memoization is controlled per registration via `memoize:`:
#   :global         (default) — one shared instance for the whole container
#   :current_fiber            — one instance per fiber, backed by Fiber-local
#                               storage. Under Async this scopes to a request;
#                               child fibers/threads inherit a copy, so a value
#                               resolved in an ancestor is shared down its tree
#                               while sibling fibers each build their own.
#   false                     — never memoized; the block runs on every resolve
module Sidereal
  class IOCContainer
    MissingDependencyDeclaration = Class.new(StandardError)

    class Definition
      def initialize(key, callable, cache:)
        @key, @callable, @cache = key, callable, cache
        @mutex = Mutex.new
      end

      # Compute-once with double-checked locking. The per-definition Mutex is
      # fiber-aware (yields under Async, blocks under raw threads) and per-fiber
      # owned, so a second fiber resolving the same key while the first is
      # yielding inside the block waits rather than re-running the block. Nested
      # resolution targets a *different* Definition's mutex, so no reentrancy is
      # required.
      def call(container)
        return @cache[@key] if @cache.key?(@key)

        @mutex.synchronize do
          return @cache[@key] if @cache.key?(@key)

          @cache[@key] = @callable.call(container)
        end
      end
    end

    # Per-fiber cache backed by Fiber-local storage (Ruby 3.2+ `Fiber[]`).
    # Under Async each request runs in its own fiber, so this memoizes per
    # request; under raw threads each thread's root fiber has separate storage,
    # so it also behaves per-thread. Each value is stored under its own
    # top-level fiber-storage key (Fiber[] nested hashes are shared by reference
    # across child fibers, which would leak between siblings). Values are boxed
    # so `key?` stays reliable even when a dependency memoizes to `nil`.
    class CurrentFiberCache
      Box = Data.define(:value)

      def initialize
        @prefix = "ioc_#{object_id}_"
      end

      def key?(key)
        !Fiber[fkey(key)].nil?
      end

      def [](key)
        Fiber[fkey(key)]&.value
      end

      def []=(key, value)
        Fiber[fkey(key)] = Box.new(value)
        value
      end

      private

      # Fiber[] keys must be Symbols on Ruby 3.2.
      def fkey(key)
        :"#{@prefix}#{key}"
      end
    end

    class NullCache
      def key?(_key)
        false
      end

      def [](_key)
        nil
      end

      def []=(_k, value)
        value
      end
    end

    def initialize(&block)
      @definitions = {}
      @global_cache = {}
      @current_fiber_cache = CurrentFiberCache.new
      @null_cache = NullCache.new
      yield self if block_given?

      @definitions.freeze
    end

    def inspect
      %(<#{self.class} [#{@definitions.keys.join(', ')}]>)
    end

    def register(name, memoize: :global, &block)
      @definitions[name.to_s] = Definition.new(name, block, cache: resolve_cache(memoize))
    end

    def resolve(name)
      name = name.to_s
      # @definitions is frozen after initialize, so reading it concurrently is
      # safe without a lock; each Definition guards its own compute-once.
      definition = definitions[name]
      raise MissingDependencyDeclaration, "no dependency declared for '#{name}'" unless definition

      definition.call(self)
    end

    alias_method :[], :resolve

    # Returns a Module that, when `include`d into a class, wires that class's
    # constructor to this container. The generated mixin:
    #   * overrides `.new` to fill any declared kwarg the caller omits, resolving
    #     it from the container (a caller-passed value — even `nil` — wins);
    #   * defines an `initialize` that assigns the declared deps to `@ivars`;
    #   * adds a private `attr_reader` per dep.
    #
    # Separate `include` calls ACCUMULATE rather than replace, and the registry
    # is inherited (a subclass adds to, or overrides, what its parent declared).
    #
    # @note Construction becomes keyword-only: the generated `.new` is
    #   `def new(**args)`, so positional constructor arguments are not supported.
    #
    # @param keys [Array<Symbol>, Hash{Symbol=>Symbol}] dependency keys.
    #   Positional symbols use the same name for the container key and the
    #   constructor kwarg; a trailing hash maps container_key => ctor_key.
    # @return [Module] a mixin to `include` into the target class.
    #
    # @example Inject dependencies straight from the container
    #   class Service
    #     include System.inject(:db, :logger)
    #   end
    #   Service.new            # db/logger resolved from the container
    #   Service.new(db: x)     # caller wins for :db, logger from the container
    #
    # @example Accumulating across includes (and inheritance)
    #   class Service
    #     include System.inject(:db)
    #     include System.inject(:logger)   # now has both :db and :logger
    #   end
    #
    # @example Mapping a container key to a different constructor kwarg
    #   class Service
    #     include System.inject(cache: :store)   # @store comes from container[:cache]
    #   end
    #
    # @example Defining your own #initialize alongside injected dependencies
    #   A class may declare its own constructor with extra arguments. Capture
    #   your own (keyword) arguments explicitly, collect the rest with `**rest`,
    #   and forward them with `super(**rest)` so the generated initializer can
    #   assign the injected dependencies:
    #
    #     class Service
    #       include System.inject(:db, :logger)
    #
    #       def initialize(name:, **rest)
    #         @name = name
    #         super(**rest)        # hands db:/logger: to the generated initializer
    #       end
    #     end
    #
    #     Service.new(name: 'svc')             # db/logger from the container
    #     Service.new(name: 'svc', db: other)  # caller overrides :db
    #
    #   Two rules make this work:
    #   * Use `super(**rest)`, NOT bare `super`. Bare `super` re-forwards your own
    #     args (e.g. `name:`), which the generated initializer does not consume,
    #     so they reach `Object#initialize` and raise ArgumentError.
    #   * Keep your constructor keyword-only (see the keyword-only note above).
    def inject(*keys)
      mapping = keys.last.is_a?(Hash) ? keys.last : keys.each.with_object({}) { |k, r| r[k] = k }
      container = self

      mod = Module.new
      mod.define_singleton_method(:included) do |base|
        unless base.instance_variable_defined?(:@__di_readers__)
          # First class in this hierarchy to use inject? Only the DI root carries
          # the generated initialize.
          di_root = !base.superclass.respond_to?(:__collect_injections__, true)
          base.extend(DependencyInjection)
          readers = Module.new
          base.instance_variable_set(:@__di_readers__, readers)
          if di_root
            # The single root initialize reads the fully-collected map via
            # self.class, so it serves the whole hierarchy. Defining one per
            # class would double-assign and clobber subclass overrides.
            readers.define_method(:initialize) do |**kwargs|
              dep_keys = self.class.send(:__collect_injections__).keys
              dep_keys.each { |k| instance_variable_set("@#{k}", kwargs[k]) }
              # Pass non-DI kwargs up so a hand-written initialize can coexist.
              super(**kwargs.except(*dep_keys))
            end
          end
          base.include(readers)
        end
        base.send(:__register_injection__, container, mapping, base.instance_variable_get(:@__di_readers__))
      end
      mod
    end

    # Class-level machinery extended onto any class that includes an `inject`
    # mixin. Only `new` is public; the registry helpers are private and reached
    # via `send`, so a host class gains no extra public API beyond the override.
    module DependencyInjection
      def new(**args)
        filled = __collect_injections__.each_with_object({}) do |(ctor_key, (container, container_key)), acc|
          acc[ctor_key] = args.key?(ctor_key) ? args[ctor_key] : container[container_key]
        end
        super(**args.merge(filled))
      end

      private

      def __injections__
        @__injections__ ||= {}
      end

      def __collect_injections__
        parent = superclass.respond_to?(:__collect_injections__, true) ? superclass.send(:__collect_injections__) : {}
        parent.merge(__injections__)
      end

      def __register_injection__(container, mapping, readers_mod)
        mapping.each do |container_key, ctor_key|
          __injections__[ctor_key] = [container, container_key]
          readers_mod.send(:attr_reader, ctor_key)
          readers_mod.send(:private, ctor_key)
        end
      end
    end

    private

    attr_reader :definitions

    def resolve_cache(memoize)
      case memoize
      when :current_fiber
        @current_fiber_cache
      when false
        @null_cache
      else
        @global_cache
      end
    end
  end
end
