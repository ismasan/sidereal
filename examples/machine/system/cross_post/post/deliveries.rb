# frozen_string_literal: true

module CrossPost
  class Post
    # One part per service, each a region of Post's publishing: the post's
    # delivery to that service.
    #
    #   initial ─Begin─▶ sending ─Confirm─▶ published (final)
    #           │                ─Reject──▶ rejected (final)       the service refused the content
    #           │                ─Fail────▶ retrying ─after 1m: Resend─▶ sending
    #           │                      └──▶ gave_up (final)        after MAX_ATTEMPTS
    #           └Begin─▶ skipped (final)                           not selected
    #
    # Begin is dispatched by publishing's entry, and places every region.
    # Publishing is done once every region is final.
    module Deliveries
      MAX_ATTEMPTS = 3

      Begin = Post.Command(:begin_deliveries)

      def self.define(service)
        part = Class.new(Sourced::Machine::Part) do
          part_of Post, prefix: "deliveries.#{service}"

          sending = const_set(:Sending, State(:sending))
          retrying = const_set(:Retrying, State(:retrying))
          published = const_set(:Published, State(:published))
          rejected = const_set(:Rejected, State(:rejected))
          gave_up = const_set(:GaveUp, State(:gave_up))
          skipped = const_set(:Skipped, State(:skipped))

          confirm = const_set(:Confirm, Command(:confirm) do
            attribute :url, Sourced::Types::String.present
          end)

          # Content the service won't take: a duplicate, a banned link.
          reject = const_set(:Reject, Command(:reject) do
            attribute :reason, Sourced::Types::String
          end)

          # Worth trying again: a timeout, a rate limit, a 5xx.
          failure = const_set(:Fail, Command(:fail) do
            attribute :reason, Sourced::Types::String
          end)

          resend = const_set(:Resend, Command(:resend))

          initial do
            command Begin => sending | skipped do |draft, _cmd|
              to(draft.targets.include?(service) ? sending : skipped)
            end
          end

          state sending do
            command confirm => published
            command reject => rejected

            command failure => retrying | gave_up do |draft, _cmd|
              to(draft.attempts[service] < MAX_ATTEMPTS ? retrying : gave_up)
            end
          end

          state retrying do
            after(60) do |_draft, _transition|
              dispatch resend
            end

            command resend => sending
          end

          final published
          final rejected
          final gave_up
          final skipped
        end

        const_set(Connections.constant_name(service), part)
      end

      ALL = SERVICES.to_h { |service| [service, define(service)] }.freeze
    end
  end
end
