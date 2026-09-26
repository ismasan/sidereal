# frozen_string_literal: true

require 'stringio'
require 'sidereal/cli'

RSpec.describe Sidereal::CLI do
  def run(*arguments)
    output = StringIO.new
    Sidereal::CLI::Application.new(arguments, name: 'sid', output: output).call
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
      text = run

      expect(text).to include('sid [-h/--help] <command>')
      expect(text).to include('Show Sidereal and Ruby versions')
      expect(text).not_to include("sidereal  #{Sidereal::VERSION}")
    end
  end

  describe '.call' do
    let(:io) { StringIO.new }

    it 'returns true when the command runs' do
      result = nil

      expect {
        result = Sidereal::CLI::Application.call(['info'], output: io)
      }.to output(/sidereal  #{Regexp.escape(Sidereal::VERSION)}/).to_stdout
      expect(result).to be(true)
    end

    it 'reports an unknown command against the top-level usage and returns false' do
      expect(Sidereal::CLI::Application.call(['bogus'], output: io)).to be(false)

      expect(io.string).to include('Could not parse token "bogus"')
      expect(io.string).to include('[-h/--help] <command>')
    end

    it 'returns false for unexpected arguments to a sub-command' do
      expect(Sidereal::CLI::Application.call(['info', 'extra'], output: io)).to be(false)

      expect(io.string).to include('Could not parse token "extra"')
    end

    it 'prints sub-command usage for --help and returns true' do
      expect(Sidereal::CLI::Application.call(['info', '--help'], output: io)).to be(true)

      expect(io.string).to include('Show Sidereal and Ruby versions')
      expect(io.string).not_to include('Could not parse token')
    end
  end

  describe '--help' do
    it 'prints usage' do
      text = run('--help')

      expect(text).to include('sid [-h/--help] <command>')
      expect(text).to include('Show Sidereal and Ruby versions')
    end
  end

  describe 'app commands' do
    it 'are not available outside an app' do
      io = StringIO.new

      expect(Sidereal::CLI::Application.call(['console'], output: io)).to be(false)
      expect(io.string).to include('Could not parse token "console"')
    end
  end

  describe '.register' do
    let(:plugin) do
      Class.new(Sidereal::CLI::Command) do
        self.description = 'A test plugin'

        options do
          option '--name <name>', 'Who to greet', default: 'world'
        end

        def call
          terminal.puts "hello #{@options[:name]}"
        end
      end
    end

    after do
      Sidereal::CLI::Application.registry.delete('plugin')
      Sidereal::CLI::Application.registry.delete('namespace')
    end

    it 'dispatches to a command registered after the application is defined' do
      Sidereal::CLI::Application.register('plugin', plugin)

      expect(run('plugin')).to eq("hello world\n")
      expect(run('plugin', '--name', 'Joe')).to eq("hello Joe\n")
    end

    it 'lists registered commands in usage' do
      Sidereal::CLI::Application.register('plugin', plugin)

      text = run('--help')

      expect(text).to include('One of: info, new, plugin.')
      expect(text).to include('A test plugin')
    end

    it 'supports plugins with their own sub-commands' do
      Sidereal::CLI::Application.register('namespace', Class.new(Sidereal::CLI::Command) {
        self.description = 'A namespaced plugin'
        nested :command, { 'plugin' => Class.new(Sidereal::CLI::Command) {
          def call = terminal.puts("nested #{parent.name}")
        } }

        def call = @command.call
      })

      expect(run('namespace', 'plugin')).to eq("nested namespace\n")
    end
  end
end
