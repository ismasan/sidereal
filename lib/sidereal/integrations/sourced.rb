# frozen_string_literal: true

# Sourced ⇄ Sidereal integration.
#
# +require 'sidereal/integrations/sourced'+ from your boot file to wire a
# {https://github.com/ismasan/sourced Sourced} backend into Sidereal.
#
# **Exception bridge.** Registers {Sidereal.exceptions} as a subscriber on
# Sourced's error strategy, so every Sourced retry / terminal failure is
# reported to Sidereal's exception registry — which renders the default
# error toasts and feeds any +on_retry+ / +on_failure+ / +on_fatal+
# subscribers (e.g. an APM hook). This works because {Sidereal::Exceptions}
# responds to +#report_retry+ / +#report_failure+, exactly the
# object-callback interface Sourced's +on_retry+ / +on_fail+ expect. When
# Sourced is the dispatcher it owns retry/fail orchestration, so Sidereal's
# own automatic exception reporting never runs — this bridge is what
# surfaces failures in the UI.
#
# Under the forking Falcon environment each worker loads boot.rb in its own
# process, so this registration (and Sourced's own store) is established
# fresh per worker — there is nothing to re-apply across the fork.
#
# Require this at load time (top-level in boot.rb), then point Sidereal at
# Sourced:
#
#   require 'sidereal/integrations/sourced'
#
#   Sourced.configure { |c| c.store = Sequel.sqlite('db/app.db') }
#
#   Sidereal.configure do |c|
#     c.store      = Sourced.config.store
#     c.dispatcher = Sourced::Dispatcher
#   end

require 'sourced'

# Report Sourced's retry / terminal-failure events to Sidereal's exception
# registry. Sourced binds these to Sidereal.exceptions#report_retry /
# #report_failure (the object-callback interface its error strategy accepts).
Sourced.config.error_strategy.on_retry Sidereal.exceptions
Sourced.config.error_strategy.on_fail Sidereal.exceptions
