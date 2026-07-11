# frozen_string_literal: true

require 'spec_helper'
require 'console'
require 'async'

RSpec.describe Sidereal::Logging do
  it 'disables Async::Task warnings on every logger the console gem builds' do
    # A brand-new logger (what a fresh serving thread/fiber would get) comes out
    # with Async::Task disabled — no dependency on the current fiber's logger.
    logger = Console::Config::DEFAULT.make_logger($stderr)
    expect(logger.enabled?(Async::Task)).to be false
  end

  it 'is prepended onto Console::Config exactly once and is idempotent' do
    described_class.quiet_async_disconnect_warnings!
    described_class.quiet_async_disconnect_warnings!

    installs = Console::Config.ancestors.count { |m| m == described_class::DisableAsyncTaskWarnings }
    expect(installs).to eq(1)
  end
end
