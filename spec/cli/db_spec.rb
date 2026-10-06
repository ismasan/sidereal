# frozen_string_literal: true

require 'tmpdir'
require 'stringio'
require 'sidereal/cli'

RSpec.describe Sidereal::CLI::DB do
  around do |example|
    pwd = Dir.pwd
    Dir.mktmpdir('sid-db') do |dir|
      @dir = dir
      example.run
    end
  ensure
    Dir.chdir(pwd)
  end

  after { %w[console commands db skills].each { |name| Sidereal::CLI.registry.delete(name) } }

  GEMFILE = "source 'https://rubygems.org'\n\ngem 'sidereal'\n"

  # The least an app needs for CLI.load_app, which chdirs into it and requires
  # its boot.rb. The components loop is what a generated app has, so a file
  # `db install` writes is picked up the next time the app loads.
  BOOT = <<~RUBY
    require 'sidereal'
    Dir[File.join(__dir__, 'config/components/**/*.rb')].sort.each { |file| require file }
  RUBY

  def app!(gemfile: GEMFILE, gitignore: nil)
    File.write(File.join(@dir, 'Gemfile'), gemfile)
    File.write(File.join(@dir, 'boot.rb'), BOOT)
    File.write(File.join(@dir, '.gitignore'), gitignore) if gitignore
    Sidereal::CLI.load_app(@dir)
    @dir
  end

  # Runs through the real command line, so nesting and option parsing are
  # exercised too. Returns what the command printed.
  def sid(*arguments)
    out = StringIO.new
    Sidereal::CLI::Application.new(arguments, name: 'sid', output: out).call
    out.string
  end

  def read(path) = File.read(File.join(@dir, path))

  def files = Dir.glob('**/*', File::FNM_DOTMATCH, base: @dir).reject { |p| File.directory?(File.join(@dir, p)) }.sort

  describe 'install' do
    it 'writes the component, the migrations directory and storage' do
      app!

      out = sid('db', 'install', '--skip-bundle')

      expect(files).to include('config/components/db.rb', 'db/migrations/.keep', 'storage/.keep')
      expect(out).to include('create  config/components/db.rb')
    end

    it 'declares db.filepath and a db component that depends on it' do
      app!
      sid('db', 'install', '--skip-bundle')

      component = read('config/components/db.rb')

      expect(component).to include(
        "c.declare('db.filepath', Sidereal::Types::String) { 'storage/db.db' }",
        "c.declare('db', Sequel::Database)",
        "c.component!('db', ['db.filepath'])",
        'teardown(&:disconnect)'
      )
    end

    it 'is valid Ruby that declares both components' do
      app!
      sid('db', 'install', '--skip-bundle')

      require File.join(@dir, 'config/components/db.rb')

      expect(Sidereal.config.declared?('db')).to be(true)
      expect(Sidereal.config.declared?('db.filepath')).to be(true)
      expect(Sidereal.config.build!['db.filepath']).to eq('storage/db.db')
    end

    it 'adds the gems it needs to the Gemfile' do
      app!

      sid('db', 'install', '--skip-bundle')

      expect(read('Gemfile')).to include("gem 'sequel'", "gem 'sqlite3'")
    end

    it 'ignores storage when nothing already does' do
      app!

      sid('db', 'install', '--skip-bundle')

      expect(read('.gitignore')).to eq("/storage/*\n!/storage/.keep\n")
    end

    it "leaves an app's existing .gitignore alone" do
      app!(gitignore: "/storage/*\n!/storage/.keep\n")

      out = sid('db', 'install', '--skip-bundle')

      expect(read('.gitignore')).to eq("/storage/*\n!/storage/.keep\n")
      expect(out).to include('skip    .gitignore')
    end

    it 'changes nothing the second time' do
      app!
      sid('db', 'install', '--skip-bundle')
      before = files.to_h { |path| [path, read(path)] }

      out = sid('db', 'install', '--skip-bundle')

      expect(files.to_h { |path| [path, read(path)] }).to eq(before)
      expect(out).to include('skip    Gemfile', 'skip    .gitignore', 'skip    config/components/db.rb')
    end

    it 'overwrites an edited component file with --force' do
      app!
      sid('db', 'install', '--skip-bundle')
      File.write(File.join(@dir, 'config/components/db.rb'), '# mine')

      sid('db', 'install', '--skip-bundle', '--force')

      expect(read('config/components/db.rb')).to include("c.declare('db', Sequel::Database)")
    end

    it 'fails outside an app' do
      File.write(File.join(@dir, 'boot.rb'), BOOT)
      Sidereal::CLI.load_app(@dir)

      expect { sid('db', 'install', '--skip-bundle') }
        .to raise_error(Sidereal::CLI::Error, /No Gemfile/)
    end
  end

  describe 'migrations add' do
    it 'writes a timestamped migration with a change block' do
      app!

      out = sid('db', 'migrations', 'add', 'Create things')

      path = Dir[File.join(@dir, 'db/migrations/*.rb')].first
      expect(File.basename(path)).to match(/\A\d{14}_create_things\.rb\z/)
      expect(File.read(path)).to include('Sequel.migration do', 'change do', '# create_table(:things) do')
      expect(out).to include('create  db/migrations/')
    end

    it 'needs a name, rather than taking the sub-command name for one' do
      app!

      expect { sid('db', 'migrations', 'add') }.to raise_error(Sidereal::CLI::Error, /Name the migration/)
      expect(Dir[File.join(@dir, 'db/migrations/*.rb')]).to be_empty
    end

    it 'refuses a name with nothing usable in it' do
      app!

      expect { sid('db', 'migrations', 'add', '---') }.to raise_error(Sidereal::CLI::Error, /usable file name/)
    end
  end

  describe 'migrations run and rollback' do
    def installed_app!
      app!
      sid('db', 'install', '--skip-bundle')
      require File.join(@dir, 'config/components/db.rb')
      @dir
    end

    # The migrator's one job, end to end against a real SQLite file.
    def add_migration!(body)
      sid('db', 'migrations', 'add', 'create_things')
      path = Dir[File.join(@dir, 'db/migrations/*.rb')].first
      File.write(path, body)
      path
    end

    it 'applies a migration, then rolls it back, then applies it again' do
      installed_app!
      add_migration!(<<~MIGRATION)
        Sequel.migration do
          change do
            create_table(:things) { primary_key :id }
          end
        end
      MIGRATION

      expect(sid('db', 'migrations', 'run')).to include('migrate', 'create_things')
      db = Sidereal.config['db']
      expect(db.tables).to include(:things)

      expect(sid('db', 'migrations', 'rollback')).to include('rollback', 'create_things')
      expect(db.tables).not_to include(:things)

      sid('db', 'migrations', 'run')
      expect(db.tables).to include(:things)
    end

    it 'says so when everything has already run' do
      installed_app!
      add_migration!("Sequel.migration { change { create_table(:things) { primary_key :id } } }\n")
      sid('db', 'migrations', 'run')

      expect(sid('db', 'migrations', 'run')).to include('Already up to date.')
    end

    # An empty db/migrations makes Sequel's own Migrator pick its integer
    # migrator, which then refuses to run at all.
    it 'says so when there are no migrations, rather than failing' do
      installed_app!

      expect(sid('db', 'migrations', 'run')).to include('No migrations in db/migrations')
      expect(sid('db', 'migrations', 'rollback')).to include('No migrations in db/migrations')
    end

    it 'says so when nothing has been applied yet' do
      installed_app!
      add_migration!("Sequel.migration { change { create_table(:things) { primary_key :id } } }\n")

      expect(sid('db', 'migrations', 'rollback')).to include('No applied migrations to roll back.')
    end

    it 'points at db install when the app has no db component' do
      app!
      FileUtils.mkdir_p(File.join(@dir, 'db/migrations'))
      File.write(File.join(@dir, 'db/migrations/20260101000000_x.rb'), "Sequel.migration { change { } }\n")

      expect { sid('db', 'migrations', 'run') }
        .to raise_error(Sidereal::CLI::Error, /no 'db' component.*db install/m)
    end
  end
end
