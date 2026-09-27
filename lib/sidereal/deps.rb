# frozen_string_literal: true

module Sidereal
  # Class-level shorthand for injecting {Sidereal.dependencies} into a class's
  # constructor.
  #
  #   class MyThing
  #     extend Sidereal::Deps
  #
  #     dep :store                     # store: keyword, and a #store reader
  #     dep 'sourced.store' => 'st'    # aliased: st: and #st
  #   end
  #
  # +dep(*specs)+ is +include Sidereal.dependencies.args(*specs)+; see
  # {Dependencies#args} for how the keyword arguments and readers work.
  # {Sidereal::Commander} extends it, so commanders can declare what their
  # handlers use.
  module Deps
    # @param specs [Array<String, Symbol, Hash{String, Symbol => String, Symbol}>]
    # @return [self]
    def dep(*specs)
      include Sidereal.dependencies.args(*specs)
    end
  end
end
