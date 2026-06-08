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
      Box = Struct.new(:value)

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

    def inject(*keys)
      map = keys.last.is_a?(Hash) ? keys.last : keys.each.with_object({}) { |k, r| r[k] = k }
      container = self

      mod = Module.new
      mod.define_method(:build) do |**args|
        opts = map.each.with_object({}) { |(container_key, constructor_key), ret|
          ret[constructor_key.to_sym] = container[container_key.to_s]
        }.merge(args)
        new(**opts)
      end
      mod
    end

    def methods(*keys)
      map = keys.last.is_a?(Hash) ? keys.last : keys.each.with_object({}) { |k, r| r[k] = k }
      container = self

      mod = Module.new
      map.each do |dep, name|
        mod.define_method(name) do
          container[dep.to_s]
        end
      end
      mod
    end

    private

    attr_reader :cache, :definitions

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
