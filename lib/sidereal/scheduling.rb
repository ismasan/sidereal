# frozen_string_literal: true

module Sidereal
  # Register a cron-scheduled block. The block runs on every tick of
  # the cron expression, on a fiber spawned by {Sidereal.scheduler}.
  # Inside the block, +dispatch(MessageClass, payload)+ enqueues a
  # command onto {Sidereal.store} stamped with
  # +metadata: { producer: '<cron expr>' }+.
  #
  # @example
  #   schedule '5 0 * * *' do
  #     dispatch Cleanup, foo: 'bar'
  #   end
  #
  # @param cron_expr [String] cron expression (5 or 6 fields)
  # @return [self]
  module Scheduling
    def schedule(cron_expr, &block)
      Sidereal.scheduler.schedule(cron_expr, &block)

      command Sidereal::System::TriggerSchedule do |cmd|
        schedule = Sidereal.scheduler.find(cmd.payload.schedule_id)
        return unless schedule

        schedule.run_in(self, cmd)
      end
      self
    end
  end
end
