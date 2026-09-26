# frozen_string_literal: true

require 'stringio'
require 'sidereal/cli'

RSpec.describe Sidereal::CLI do
  def run(*arguments)
    output = StringIO.new
    Sidereal::CLI::Top.new(arguments, name: 'sid', output: output).call
    output.string
  end

  describe 'info' do
    it 'prints the Sidereal and Ruby versions' do
      text = run('info')

      expect(text).to include("sidereal  #{Sidereal::VERSION}")
      expect(text).to include("ruby      #{RUBY_DESCRIPTION}")
    end
  end

  describe 'without a command' do
    it 'prints usage listing the available commands' do
      expect(run).to include('sid [-h/--help] <command>').and include('info')
    end
  end

  describe '--help' do
    it 'prints usage' do
      expect(run('--help')).to include('Show Sidereal and Ruby versions')
    end
  end
end
