# frozen_string_literal: true

require 'tmpdir'
require 'stringio'
require 'sidereal/cli'

RSpec.describe Sidereal::CLI::Sourced do
  around do |example|
    pwd = Dir.pwd
    Dir.mktmpdir('sid-sourced') do |dir|
      @dir = dir
      example.run
    end
  ensure
    Dir.chdir(pwd)
  end

  after do
    %w[console commands db sourced skills].each { |name| Sidereal::CLI.registry.delete(name) }
    Sidereal::CLI::Sourced::COMMANDS.delete('migration')
    Sidereal::CLI::Sourced::COMMANDS.delete('topology')
  end

  # Enough for CLI.load_app: it chdirs in and requires boot.rb.
  def app!
    File.write(File.join(@dir, 'Gemfile'), "source 'https://rubygems.org'\n\ngem 'sidereal'\n")
    File.write(File.join(@dir, 'boot.rb'), <<~RUBY)
      require 'sidereal'
      Dir[File.join(__dir__, 'config/components/**/*.rb')].sort.each { |file| require file }
    RUBY
    Sidereal::CLI.load_app(@dir)
    @dir
  end

  def sid(*arguments)
    out = StringIO.new
    Sidereal::CLI::Application.new(arguments, name: 'sid', output: out).call
    out.string
  end

  def read(path) = File.read(File.join(@dir, path))

  describe 'install' do
    it 'installs a database too, since Sourced keeps its messages there' do
      app!

      out = sid('sourced', 'install', '--skip-bundle')

      expect(out).to include('config/components/db.rb', 'config/components/sourced.rb')
      expect(read('config/components/db.rb')).to include("c.declare('db', Sequel::Database)")
    end

    it 'writes a component that uses the integration on that db' do
      app!

      sid('sourced', 'install', '--skip-bundle')

      expect(read('config/components/sourced.rb')).to include(
        "require 'sidereal/integrations/sourced'",
        "Sidereal.config.use Sidereal::Integrations::Sourced, db: 'db'"
      )
    end

    it 'adds the gem from its branch' do
      app!

      sid('sourced', 'install', '--skip-bundle')

      expect(read('Gemfile')).to include("gem 'sourced', github: 'ismasan/sourced', branch: 'ccc'")
    end

    # The gem is only bundled at the end of this command, so this process can't
    # render the migration — its load path was fixed before the gem existed.
    it "renders Sourced's migration in a fresh process, after bundling" do
      app!
      commands = []
      allow_any_instance_of(Sidereal::CLI::Installer).to receive(:run!) { |_, *command| commands << command }

      sid('sourced', 'install')

      expect(commands).to eq([%w[bundle install], %w[bundle install],
                              %w[bin/sid sourced migration], %w[bin/sid db migrations run]])
    end

    it 'passes --force through to the migration' do
      app!
      commands = []
      allow_any_instance_of(Sidereal::CLI::Installer).to receive(:run!) { |_, *command| commands << command }

      sid('sourced', 'install', '--force')

      expect(commands).to include(%w[bin/sid sourced migration --force])
    end

    it 'says how to finish by hand with --skip-bundle' do
      app!

      out = sid('sourced', 'install', '--skip-bundle')

      expect(out).to include('bin/sid sourced migration', 'bin/sid db migrations run')
    end

    it 'changes nothing the second time' do
      app!
      sid('sourced', 'install', '--skip-bundle')

      out = sid('sourced', 'install', '--skip-bundle')

      expect(out).to include('skip    Gemfile', 'skip    config/components/sourced.rb')
    end
  end

  describe 'the namespace' do
    it 'has install before the app has configured anything' do
      expect(described_class::COMMANDS).to include('install' => Sidereal::CLI::Sourced::Install)
    end
  end
end
