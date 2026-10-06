# frozen_string_literal: true

require 'tmpdir'
require 'bundler'
require 'sidereal/cli'

RSpec.describe Sidereal::CLI::Installer do
  around do |example|
    Dir.mktmpdir('sid-installer') { |dir| @dir = dir; example.run }
  end

  subject(:installer) { described_class.new(@dir) }

  def write(path, content)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def read(path) = File.read(File.join(@dir, path))

  def gemfile!(body = "source 'https://rubygems.org'\n\ngem 'rake'\n") = write('Gemfile', body)

  # What Bundler makes of the Gemfile — the only reading of it that counts.
  def dependencies
    dsl = Bundler::Dsl.new
    dsl.eval_gemfile(File.join(@dir, 'Gemfile'))
    dsl.dependencies
  end

  describe '#gems' do
    it 'appends the ones the Gemfile does not ask for' do
      gemfile!

      expect(installer.gems('sequel', 'sqlite3')).to eq([[:update, 'Gemfile']])
      expect(dependencies.map(&:name)).to contain_exactly('rake', 'sequel', 'sqlite3')
    end

    it 'adds only what is missing' do
      gemfile!("source 'https://rubygems.org'\ngem 'sequel'\n")

      installer.gems('sequel', 'sqlite3')

      expect(dependencies.map(&:name).tally).to eq('sequel' => 1, 'sqlite3' => 1)
    end

    it 'does nothing when they are all there' do
      gemfile!("source 'https://rubygems.org'\ngem 'sequel'\ngem 'sqlite3'\n")
      before = read('Gemfile')

      expect(installer.gems('sequel', 'sqlite3')).to eq([[:skip, 'Gemfile']])
      expect(read('Gemfile')).to eq(before)
    end

    # What an integration needs: a gem from somewhere other than rubygems.
    it 'passes options through to the gem line' do
      gemfile!

      installer.gems('sourced', github: 'ismasan/sourced', branch: 'ccc')

      expect(read('Gemfile')).to include("gem 'sourced', github: 'ismasan/sourced', branch: 'ccc'")
      expect(dependencies.find { |d| d.name == 'sourced' }).not_to be_nil
    end

    it 'writes a comment above the gems it adds' do
      gemfile!

      installer.gems('sequel', comment: '# For the database.')

      expect(read('Gemfile')).to include("# For the database.\ngem 'sequel'\n")
    end

    # A declaration a text scan would miss, and so add a second time.
    it 'finds a gem declared with parentheses inside a group' do
      gemfile!("source 'https://rubygems.org'\ngroup :development do\n  gem(\"sqlite3\")\nend\n")

      expect(installer.gems('sqlite3')).to eq([[:skip, 'Gemfile']])
    end

    it 'is not fooled by a commented-out gem line' do
      gemfile!("source 'https://rubygems.org'\n# gem 'sequel'\n")

      installer.gems('sequel')

      expect(dependencies.map(&:name)).to include('sequel')
    end

    it 'refuses an app with no Gemfile' do
      expect { installer.gems('sequel') }.to raise_error(Sidereal::CLI::Error, /No Gemfile/)
    end

    it 'refuses a Gemfile it cannot read' do
      gemfile!("source 'https://rubygems.org'\n(((\n")

      expect { installer.gems('sequel') }.to raise_error(Sidereal::CLI::Error, /Couldn't read/)
    end
  end

  describe '#ignore' do
    it 'creates a .gitignore when the app has none' do
      expect(installer.ignore('/storage/*')).to eq([[:create, '.gitignore']])
      expect(read('.gitignore')).to eq("/storage/*\n")
    end

    it 'appends only the lines that are not already there' do
      write('.gitignore', "/tmp\n/storage/*\n")

      expect(installer.ignore('/storage/*', '!/storage/.keep')).to eq([[:update, '.gitignore']])
      expect(read('.gitignore')).to eq("/tmp\n/storage/*\n!/storage/.keep\n")
    end

    it 'does nothing when every line is there' do
      write('.gitignore', "/storage/*\n!/storage/.keep\n")

      expect(installer.ignore('/storage/*', '!/storage/.keep')).to eq([[:skip, '.gitignore']])
      expect(read('.gitignore')).to eq("/storage/*\n!/storage/.keep\n")
    end
  end

  describe '#templates' do
    it 'keeps a file the app already has, and reports it' do
      source = File.join(@dir, 'templates')
      FileUtils.mkdir_p(source)
      File.write(File.join(source, 'kept.rb'), 'from the template')
      File.write(File.join(source, 'fresh.rb'), 'new')
      write('kept.rb', 'edited by hand')

      actions = installer.templates(source, Object.new)

      expect(actions).to contain_exactly([:skip, 'kept.rb'], [:create, 'fresh.rb'])
      expect(read('kept.rb')).to eq('edited by hand')
    end

    it 'overwrites with overwrite: true' do
      source = File.join(@dir, 'templates')
      FileUtils.mkdir_p(source)
      File.write(File.join(source, 'kept.rb'), 'from the template')
      write('kept.rb', 'edited by hand')

      expect(installer.templates(source, Object.new, overwrite: true)).to eq([[:create, 'kept.rb']])
      expect(read('kept.rb')).to eq('from the template')
    end
  end

  describe '#run!' do
    it 'runs the command in the app' do
      installer.run!('sh', '-c', 'pwd > where.txt')

      expect(read('where.txt').strip).to eq(File.realpath(@dir))
    end

    it 'raises when the command fails' do
      expect { installer.run!('sh', '-c', 'exit 3') }
        .to raise_error(Sidereal::CLI::Error, /`sh -c exit 3` failed/)
    end
  end
end
