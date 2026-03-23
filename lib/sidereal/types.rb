# frozen_string_literal: true

require 'securerandom'
require 'plumb'

module Sidereal
  module Types
    include Plumb::Types

    AutoUUID = UUID::V4.default { SecureRandom.uuid }
  end
end
