# frozen_string_literal: true

module Sidereal
  # Register a cron-scheduled block. The block runs on every tick of
  # the cron expression, dispatched as a +TriggerSchedule+ command and
  # handled by this commander's worker pool. Inside the block,
  # +dispatch(MessageClass, payload)+ enqueues commands onto
  # {Sidereal.store} stamped with a +producer+ metadata string
  # ("Schedule #<id> '<name>' (<cron_expr>)") that propagates via
  # +Message#correlate+.
  #
  # Two call shapes — see {Sidereal::Scheduler#schedule}:
  # @example Auto-named
  #   schedule '5 0 * * *' do |cmd|
  #     dispatch Cleanup, foo: 'bar'
  #   end
  # @example Named
  #   schedule 'Recurring cleanup', '5 0 * * *' do |cmd|
  #     dispatch Cleanup, foo: 'bar'
  #   end
  #
  # @return [self]
  module Scheduling
    def schedule(...)
      Sidereal.scheduler.schedule(...)

      command Sidereal::System::TriggerSchedule do |cmd|
        schedule = Sidereal.scheduler.find(cmd.payload.schedule_id)
        return unless schedule

        schedule.run_in(self, cmd)
      end
      self
    end
  end
end
