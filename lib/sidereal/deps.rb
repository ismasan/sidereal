# frozen_string_literal: true

module Sidereal
  # Class-level shorthand for injecting {Sidereal.config}'s components into a
  # class's constructor.
  #
  #   class MyThing
  #     extend Sidereal::Deps
  #
  #     dep :db                        # db: keyword, and a #db reader
  #     dep 'sourced.store' => 'st'    # aliased: st: and #st
  #   end
  #
  # +dep(*keys)+ is +include Sidereal.config.inject(*keys)+: keys are relative
  # to the root, and values are read when an object is instantiated, so
  # +Sidereal.config+ must be built by then. Any one can be passed explicitly
  # instead (+MyThing.new(db: fake)+). Injecting a name the class already has
  # a method for raises: alias it. {Sidereal::Commander} extends it, so
  # commanders can declare what their handlers use.
  module Deps
    # @param keys [Array<String, Symbol, Hash{String, Symbol => String, Symbol}>]
    # @return [self]
    def dep(*keys)
      include Sidereal.config.inject(*keys)
    end
  end
end
