# frozen_string_literal: true

require 'stringio'
require 'sidereal/cli'

RSpec.describe Sidereal::CLI::Secret do
  it 'prints a new secret long enough for Sidereal::KeyGenerator' do
    secret = capture_secret

    expect(secret).to match(/\A\h{64}\z/)
    expect { Sidereal::KeyGenerator.new(secret) }.not_to raise_error
  end

  it 'prints a different one each time' do
    expect(capture_secret).not_to eq(capture_secret)
  end

  def capture_secret
    original = $stdout
    $stdout = StringIO.new
    expect(Sidereal::CLI::Application.call(['secret'])).to be(true)
    $stdout.string.chomp
  ensure
    $stdout = original
  end
end
