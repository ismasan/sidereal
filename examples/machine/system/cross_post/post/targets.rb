# frozen_string_literal: true

module CrossPost
  class Post
    # One part per service, each a region of Post's drafting:
    # whether the post goes to that service, and whether it meets the
    # service's Rules.
    #
    #   initial ─Sync─▶ available ─Select─▶ valid ⇄ invalid (Validate)
    #           └Sync─▶ unavailable ⇄ available (Enable / Disable)
    #   valid, invalid ─Deselect─▶ available
    #   valid, invalid ─Disable──▶ unavailable
    #
    # Sync is dispatched by drafting's entry: every region's initial position
    # accepts it, so one command places all of them. Validate is dispatched
    # after every edit, and taken by every selected region. Enable and Disable
    # come from Account, as the service's connection comes and goes.
    #
    # Each service gets its own part because each has its own commands
    # (Post::Targets::X::Select): a handler can't tell which placement of a
    # part mounted twice it runs in.
    module Targets
      Sync = Post.Command(:sync_targets)
      Validate = Post.Command(:validate_targets)

      def self.define(service)
        part = Class.new(Sourced::Machine::Part) do
          part_of Post, prefix: "targets.#{service}"

          unavailable = const_set(:Unavailable, State(:unavailable))
          available = const_set(:Available, State(:available))
          valid = const_set(:Valid, State(:valid))
          invalid = const_set(:Invalid, State(:invalid))

          enable = const_set(:Enable, Command(:enable))
          disable = const_set(:Disable, Command(:disable))
          select = const_set(:Select, Command(:select))
          deselect = const_set(:Deselect, Command(:deselect))

          initial do
            command Sync => available | unavailable do |draft, _cmd|
              to(draft.services.include?(service) ? available : unavailable)
            end
          end

          state unavailable do
            command enable => available
          end

          state available do
            command select => valid | invalid do |draft, _cmd|
              to(draft.valid_for?(service) ? valid : invalid)
            end

            command disable => unavailable
          end

          state valid do
            command Validate => invalid | nil do |draft, _cmd|
              to invalid unless draft.valid_for?(service)
            end

            command deselect => available
            command disable => unavailable
          end

          state invalid do
            command Validate => valid | nil do |draft, _cmd|
              to valid if draft.valid_for?(service)
            end

            command deselect => available
            command disable => unavailable
          end
        end

        const_set(Connections.constant_name(service), part)
      end

      ALL = SERVICES.to_h { |service| [service, define(service)] }.freeze
    end
  end
end
