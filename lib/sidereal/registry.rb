# frozen_string_literal: true

module Sidereal
  # Maps command classes to the single Commander class that handles them.
  # Hash-like access. Assigning a different commander for an already-claimed
  # command class raises DuplicateHandler.
  class Registry
    DuplicateHandler = Class.new(Sidereal::Error)

    def initialize
      @table = {}
    end

    def []=(cmd_class, commander_class)
      existing = @table[cmd_class]
      if existing && existing != commander_class
        raise DuplicateHandler,
              "Command #{cmd_class} is already handled by #{existing}; " \
              "cannot also register #{commander_class}"
      end
      @table[cmd_class] = commander_class
    end

    def [](cmd_class) = @table[cmd_class]

    def clear
      @table.clear
      self
    end
  end
end
