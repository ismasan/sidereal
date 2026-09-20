# frozen_string_literal: true

# The things people comment on. A hard-coded stand-in for a posts table:
# fixed UUIDs so events recorded today still resolve after a restart.
module Subjects
  Subject = Data.define(:id, :title)

  ALL = [
    Subject.new(id: '6f1c9d2e-0b3a-4e8f-9a4d-1c2b3e4f5a60', title: 'My take on geopolitics'),
    Subject.new(id: '7a2d0e3f-1c4b-4f90-8b5e-2d3c4f506b71', title: 'Why I switched to a standing desk'),
    Subject.new(id: '8b3e1f40-2d5c-4a01-9c6f-3e4d50617c82', title: 'Sourdough, three years in')
  ].freeze

  BY_ID = ALL.to_h { |s| [s.id, s] }.freeze

  def self.all = ALL
  def self.first = ALL.first
  def self.find(id) = BY_ID[id.to_s]
  def self.exists?(id) = BY_ID.key?(id.to_s)
end
