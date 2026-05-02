# frozen_string_literal: true

module Sidereal
  # System-level commands dispatched by the framework itself.
  #
  # When a user command's handler raises and the dispatcher's
  # {Commander.on_error} returns +Store::Result::Retry+ or +Result::Fail+,
  # the dispatcher appends one of these to the store. They flow through
  # the normal command pipeline — handled by the App's commander
  # (no-op by default), published via pubsub, and observable by Pages
  # for reactive UI (e.g. flash a "retrying" notice, show an error
  # panel in dev mode).
  #
  # Apps can override the no-op handlers via the standard +command+
  # DSL to update application state. **Care must be taken that custom
  # handlers don't raise** — a raising NotifyFailure handler would itself
  # be retried/failed, but the dispatcher short-circuits the cascade by
  # not dispatching new notifications for failures of system commands.
  module System
    # Marker base for framework-dispatched system messages. Code that
    # needs to apply system-wide behavior (skip notification-loop
    # dispatch, channel bypass in {App.channel_name}, default no-op
    # registration in {Commander.inherited}) checks
    # +msg.is_a?(Notification)+ rather than enumerating concrete
    # subclasses, so adding a new system message just means
    # +Notification.define(...)+.
    class Notification < Sidereal::Message
    end

    # Dispatched when a handler raises and policy chose to retry.
    NotifyRetry = Notification.define('sidereal.system.notify_retry') do
      attribute :command_type, Sidereal::Types::String
      attribute :command_id, Sidereal::Types::String
      attribute :command_payload, Sidereal::Types::Hash.default(Plumb::BLANK_HASH)
      attribute :attempt, Sidereal::Types::Integer
      attribute :retry_at, Sidereal::Types::String # ISO8601
      attribute :error_class, Sidereal::Types::String
      attribute :error_message, Sidereal::Types::String
      attribute :backtrace, Sidereal::Types::Array.default([].freeze)
    end

    # Dispatched when a handler raises and policy chose to dead-letter.
    NotifyFailure = Notification.define('sidereal.system.notify_failure') do
      attribute :command_type, Sidereal::Types::String
      attribute :command_id, Sidereal::Types::String
      attribute :command_payload, Sidereal::Types::Hash.default(Plumb::BLANK_HASH)
      attribute :attempt, Sidereal::Types::Integer
      attribute :error_class, Sidereal::Types::String
      attribute :error_message, Sidereal::Types::String
      attribute :backtrace, Sidereal::Types::Array.default([].freeze)
    end

    TriggerSchedule = Notification.define('sidereal.system.trigger_schedule') do
      attribute :schedule_id, Sidereal::Types::Integer
      attribute :schedule_name, Sidereal::Types::String.present
    end
  end
end
