# frozen_string_literal: true

require 'tmpdir'
require 'stringio'
require 'open3'
require 'json'
require 'yaml'
require 'rbconfig'
require 'sidereal/cli'

RSpec.describe Sidereal::CLI::New do
  # The generated app's pubsub socket lives under <app>/storage, and Unix
  # socket paths are limited to ~100 bytes, too short for the system temp
  # directory on macOS. Use the repository's (git-ignored) tmp/ instead.
  TMP = File.expand_path('../../tmp', __dir__)

  around do |example|
    FileUtils.mkdir_p(TMP)
    Dir.mktmpdir('sid', TMP) do |dir|
      @dir = dir
      example.run
    end
  end

  let(:io) { StringIO.new }

  def sid_new(*arguments)
    Sidereal::CLI::Application.call(['new', *arguments], output: io)
  end

  # Generates without printing progress to the spec output.
  def generate(name = 'app', *arguments)
    result = nil
    expect {
      result = sid_new(File.join(@dir, name), '--skip-bundle', *arguments)
    }.to output.to_stdout
    expect(result).to be(true), io.string
    File.join(@dir, name)
  end

  def read(root, path) = File.read(File.join(root, path))

  def files(root)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: root)
      .reject { |path| File.directory?(File.join(root, path)) }
      .sort
  end

  it 'generates the app skeleton' do
    root = generate('my_app')

    expect(files(root)).to eq(%w[
      .gitignore
      Gemfile
      README.md
      bin/dev
      bin/sid
      boot.rb
      config.ru
      config/components/example.rb
      falcon.rb
      storage/.keep
      system/greetings.rb
      web/app.rb
      web/public/css/app.css
      web/ui/components/hello.rb
      web/ui/layout.rb
      web/ui/welcome_page.rb
    ])
  end

  it 'titles the app after the directory' do
    root = generate('my_app')

    expect(read(root, 'web/ui/layout.rb')).to include("title { 'My App' }")
    expect(read(root, 'README.md')).to start_with("# My App\n")
    expect(read(root, 'system/greetings.rb')).to include("'my_app.greetings.say_hello'")
  end

  it 'generates valid Ruby' do
    root = generate('my_app', '--rspec', '--sourced')

    ruby_files = files(root).select { |path| path.end_with?('.rb', '.ru', 'Gemfile') }
    expect(ruby_files).not_to be_empty
    ruby_files.each do |path|
      expect { RubyVM::InstructionSequence.compile(read(root, path)) }.not_to raise_error, path
    end
  end

  describe 'after generating' do
    # Records the commands `sid new` runs in the app instead of running them.
    def commands_run(*arguments)
      commands = []
      allow_any_instance_of(Sidereal::CLI::Installer).to receive(:run!) { |_, *command| commands << command }
      expect { expect(sid_new(File.join(@dir, 'app'), *arguments)).to be(true), io.string }.to output.to_stdout
      commands
    end

    it 'bundles, then installs skills' do
      expect(commands_run).to eq([%w[bundle install], %w[bin/sid skills update]])
    end

    it "doesn't install skills with --no-skills" do
      expect(commands_run('--no-skills')).to eq([%w[bundle install]])
    end

    it 'says to install skills with --skip-bundle' do
      expect { sid_new(File.join(@dir, 'app'), '--skip-bundle') }.to output(%r{bundle install\n\s+bin/sid skills update\n}).to_stdout
    end

    it "doesn't mention skills with --skip-bundle --no-skills" do
      expect { sid_new(File.join(@dir, 'app'), '--skip-bundle', '--no-skills') }.not_to output(/skills/).to_stdout
    end
  end

  describe 'Gemfile' do
    it 'uses Sidereal from GitHub by default' do
      root = generate

      expect(read(root, 'Gemfile')).to include("gem 'sidereal', github: 'ismasan/sidereal'")
    end

    it 'uses a local Sidereal checkout with --sidereal-path' do
      root = generate('app', '--sidereal-path', @dir)

      expect(read(root, 'Gemfile')).to include("gem 'sidereal', path: '#{File.expand_path(@dir)}'")
    end

    it 'includes Falcon and Zeitwerk, and nothing optional' do
      gemfile = read(generate, 'Gemfile')

      expect(gemfile).to include("gem 'falcon'", "gem 'zeitwerk'")
      expect(gemfile).not_to include('rspec')
      expect(gemfile).not_to include('sourced')
    end

    it 'adds RSpec with --rspec' do
      expect(read(generate('app', '--rspec'), 'Gemfile')).to include("group :test do\n  gem 'rspec'\nend")
    end

    it 'adds Sourced and SQLite with --sourced' do
      gemfile = read(generate('app', '--sourced'), 'Gemfile')

      expect(gemfile).to include("gem 'sourced', github: 'ismasan/sourced', branch: 'ccc'")
      expect(gemfile).to include("gem 'sequel'", "gem 'sqlite3'")
    end
  end

  describe 'boot.rb' do
    it 'loads config/components before configuring Sidereal, so the configuration can name them' do
      boot = read(generate, 'boot.rb')

      expect(boot).to include("Dir[File.join(__dir__, 'config/components/**/*.rb')].sort.each { |file| require file }")
      expect(boot.index('config/components/**')).to be < boot.index('Sidereal.config.use_file_system!')
    end

    it 'comes with an example component file, all commented out' do
      example = read(generate('app', '--sourced'), 'config/components/example.rb')
      code = example.lines.reject { |line| line.strip.empty? || line.start_with?('#') }

      expect(code).to eq([])
      expect(example).to include("declare('mailer'", "component!('mailer')", "config!('sidereal.workers.count')", 'dep :mailer')
      expect(read(generate('plain'), 'config/components/example.rb')).not_to include('Sourced')
    end

    it 'uses the file system backend' do
      boot = read(generate, 'boot.rb')

      expect(boot).to include('Sidereal.config.use_file_system!')
      expect(boot).not_to include('Integrations::Sourced')
    end

    it 'adds the Sourced integration with --sourced, on a db component' do
      root = generate('app', '--sourced')

      expect(read(root, 'boot.rb')).to include(
        "require 'sidereal/integrations/sourced'",
        "Sidereal.config.use Sidereal::Integrations::Sourced, db: 'db'"
      )
      expect(read(root, 'config/components/db.rb')).to include("Sidereal.config.declare('db', Sequel::Database)", 'storage/app.db')
    end

    it 'leaves out the db component without --sourced' do
      expect(files(generate)).not_to include('config/components/db.rb')
    end
  end

  describe 'generated app' do
    # Boots config.ru in a separate process (it configures process-global
    # Sidereal state) and requests the welcome page.
    def get_root(root)
      script = <<~RUBY
        require 'rack'
        app = Rack::Builder.parse_file('config.ru')
        response = Rack::MockRequest.new(app).get('/')
        $stderr.print response.status, "\\n", response.body
      RUBY
      _stdout, response, status = Open3.capture3(RbConfig.ruby, '-e', script, chdir: root)
      [response, status]
    end

    it 'boots and renders the welcome page' do
      root = generate('app')

      out, status = get_root(root)

      expect(status).to be_success, out
      expect(out).to start_with("200\n")
      expect(out).to include('<h1 class="welcome__title">App</h1>', 'Say hello')
      # A single root element with an id, so a reconnect replaces the whole page.
      expect(out).to include('<div class="page"><div id="welcome-page">')
      expect(out).to include('<code>bin/sid commands dispatch app.greetings.say_hello --name Sidereal</code>')
      expect(out).to include('<button type="button" class="copy-button"')
      expect(out).to include('<a href="https://ismasan.github.io/sidereal/">Sidereal docs</a>')
    end

    it 'boots and renders the welcome page with --sourced' do
      root = generate('app', '--sourced')

      out, status = get_root(root)

      expect(status).to be_success, out
      expect(out).to start_with("200\n")
    end
  end

  describe 'bin/sid' do
    # Runs the generated binstub in a separate process: it registers app
    # commands in the process-global CLI. BUNDLE_GEMFILE is inherited from
    # this process, so the binstub uses Sidereal's bundle rather than the
    # generated (not installed) one.
    def bin_sid(root, *arguments, stdin_data: '', chdir: root)
      Open3.capture2e(File.join(root, 'bin/sid'), *arguments, stdin_data:, chdir:)
    end

    it 'is executable, as is bin/dev' do
      root = generate

      expect(File.executable?(File.join(root, 'bin/sid'))).to be(true)
      expect(File.executable?(File.join(root, 'bin/dev'))).to be(true)
    end

    it 'adds app commands to the usage' do
      out, status = bin_sid(generate, '--help')

      expect(status).to be_success, out
      expect(out).to include('console', 'Start an IRB session with the app loaded')
    end

    it "lists an integration's commands, which it registers when the app configures it" do
      out, status = bin_sid(generate('app', '--sourced'), '--help')

      expect(status).to be_success, out
      expect(out).to include('sourced', "Inspect the app's Sourced setup")
    end

    # Loading the app lets its integrations register commands and skills;
    # building it, which opens connections, is left to the commands that need
    # component values. So usage connects to nothing.
    it 'loads the app without building it, so --help opens no database' do
      root = generate('app', '--sourced')
      FileUtils.rm_f(Dir[File.join(root, 'storage/*')])

      out, status = bin_sid(root, '--help')

      expect(status).to be_success, out
      expect(Dir[File.join(root, 'storage/*')]).to be_empty
    end

    describe 'an app that fails to load' do
      it 'still prints usage, and says why' do
        root = generate
        File.write(File.join(root, 'boot.rb'), "raise 'boom'\n", mode: 'a')

        out, status = bin_sid(root, '--help')

        expect(status).to be_success, out
        expect(out).to include('failed to load', 'boom')
        expect(out).to include('[-h/--help]')
      end

      it 'fails loudly for a command that needs the app' do
        root = generate
        File.write(File.join(root, 'boot.rb'), "raise 'boom'\n", mode: 'a')

        out, status = bin_sid(root, 'commands', 'list')

        expect(status).not_to be_success
        expect(out).to include('boom')
      end
    end

    # The db commands are built in, so they work in an app that has no
    # database yet — which is the point of `db install`.
    it 'installs and migrates a database' do
      root = generate

      out, status = bin_sid(root, 'db', 'install', '--skip-bundle')
      expect(status).to be_success, out
      expect(out).to include('create  config/components/db.rb', 'update  Gemfile')
      expect(read(root, 'Gemfile')).to include("gem 'sequel'", "gem 'sqlite3'")

      out, status = bin_sid(root, 'db', 'migrations', 'run')
      expect(status).to be_success, out
      expect(out).to include('No migrations in db/migrations')

      out, status = bin_sid(root, 'db', 'migrations', 'add', 'create_things')
      expect(status).to be_success, out
      migration = Dir[File.join(root, 'db/migrations/*.rb')].first
      expect(File.basename(migration)).to match(/\A\d{14}_create_things\.rb\z/)
      File.write(migration, "Sequel.migration { change { create_table(:things) { primary_key :id } } }\n")

      out, status = bin_sid(root, 'db', 'migrations', 'run')
      expect(status).to be_success, out
      expect(out).to include('migrate', 'create_things')

      out, status = bin_sid(root, 'db', 'migrations', 'rollback')
      expect(status).to be_success, out
      expect(out).to include('rollback', 'create_things')
    end

    it 'starts a console with the app loaded, from any directory' do
      root = generate

      out, status = bin_sid(root, 'console', stdin_data: "puts App.name, UI::WelcomePage.name, Dir.pwd\n",
        chdir: File.join(root, 'web'))

      expect(status).to be_success, out
      expect(out).to include("App\nUI::WelcomePage\n#{File.realpath(root)}\n")
    end

    it 'loads components from config/components, nested too, and builds them' do
      root = generate
      FileUtils.mkdir_p(File.join(root, 'config/components/services'))
      File.write(File.join(root, 'config/components/services/greeter.rb'), <<~RUBY)
        Sidereal.config.declare('greeter', String)
        Sidereal.config.config!('greeter') { 'hello from greeter' }
      RUBY

      out, status = bin_sid(root, 'console', stdin_data: "puts Sidereal.config['greeter']\n")

      expect(status).to be_success, out
      expect(out).to include('hello from greeter')
    end

    it "lists the app's commands" do
      out, status = bin_sid(generate, 'commands', 'list')

      expect(status).to be_success, out
      expect(out).to match(/^Command\s+Class\s+Handled by\s+Web$/)
      expect(out).to match(/^app\.greetings\.say_hello\s+Greetings::SayHello\s+App::Commander\s+yes$/)
    end

    it "adds each command's payload schema under it with --schemas" do
      out, status = bin_sid(generate, 'commands', 'list', '--schemas')

      expect(status).to be_success, out
      lines = out.lines(chomp: true)
      expect(lines[1]).to match(/^app\.greetings\.say_hello\s+Greetings::SayHello\s+App::Commander\s+yes$/)
      expect(lines[2]).to start_with('  ')
      expect(JSON.parse(lines[2])).to eq(
        'type' => 'object',
        'properties' => { 'name' => { 'type' => 'string' } },
        'required' => ['name']
      )
    end

    it "prints a command's payload schema as a table, found by class name or type" do
      root = generate

      %w[Greetings::SayHello app.greetings.say_hello].each do |name|
        out, status = bin_sid(root, 'commands', 'info', name)

        expect(status).to be_success, out
        expect(out).to include('app.greetings.say_hello  Greetings::SayHello')
        expect(out).to match(/^Handled by\s+App::Commander$/)
        expect(out).to match(/^Web\s+yes$/)
        expect(out).to match(/^Attribute\s+Type\s+Required$/)
        expect(out).to match(/^name\s+string\s+yes$/)
      end
    end

    it "prints a command's payload JSON Schema with --json" do
      out, status = bin_sid(generate, 'commands', 'info', 'Greetings::SayHello', '--json')

      expect(status).to be_success, out
      expect(JSON.parse(out)).to eq(
        'type' => 'object',
        'properties' => { 'name' => { 'type' => 'string' } },
        'required' => ['name']
      )
    end

    it 'fails for a command the app does not know' do
      out, status = bin_sid(generate, 'commands', 'info', 'Nope')

      expect(status).not_to be_success
      expect(out).to include('No command named "Nope"')
    end

    it 'dispatches a command, coercing its attributes, into the app store' do
      root = generate
      File.write(File.join(root, 'system/kitchen.rb'), <<~RUBY)
        module Kitchen
          Order = Sidereal::Message.define('app.kitchen.order') do
            attribute :dish, Sidereal::Types::String.present
            attribute :quantity, Sidereal::Types::Integer
            attribute :gift, Sidereal::Types::Boolean
            attribute :tags, Sidereal::Types::Array[Sidereal::Types::String]
            attribute :table do
              attribute :number, Sidereal::Types::Integer
            end
          end

          class Commander < Sidereal::Commander
            command Order do |_cmd|
            end
          end
        end
      RUBY
      File.write(File.join(root, 'boot.rb'), "Sidereal.register(Kitchen::Commander)\n", mode: 'a')

      out, status = bin_sid(root, 'commands', 'dispatch', 'Kitchen::Order',
                            '--dish', 'Pizza', '--quantity', '2', '--gift', '--tags', 'vegan', '--table.number', '4')

      expect(status).to be_success, out
      expect(out).to include('Dispatched app.kitchen.order  Kitchen::Order')
      expect(out).to include('quantity  2', 'gift  true', 'tags  ["vegan"]', 'table  {number: 4}')

      ready = Dir[File.join(root, 'storage/store/ready/*.json')]
      expect(ready.size).to eq(1)
      message = JSON.parse(File.read(ready.first))
      expect(message).to include('type' => 'app.kitchen.order')
      expect(message['payload']).to eq(
        'dish' => 'Pizza', 'quantity' => 2, 'gift' => true, 'tags' => ['vegan'], 'table' => { 'number' => 4 }
      )
    end

    it 'explains the attribute syntax with dispatch --help, without dispatching' do
      root = generate

      out, status = bin_sid(root, 'commands', 'dispatch', 'Greetings::SayHello', '--name', 'Ada', '--help')

      expect(status).to be_success, out
      expect(out).to include('dispatch <class_name> <attributes...>', '--address.city Paris', '--tags a --tags b')
      expect(Dir[File.join(root, 'storage/store/ready/*')]).to be_empty
    end

    it 'does not dispatch a command with invalid attributes' do
      root = generate

      out, status = bin_sid(root, 'commands', 'dispatch', 'Greetings::SayHello', '--name', '')

      expect(status).not_to be_success
      expect(out).to include("Not dispatched. Invalid attributes for app.greetings.say_hello:\n  --name: must be present")
      expect(Dir[File.join(root, 'storage/store/ready/*')]).to be_empty

      out, status = bin_sid(root, 'commands', 'dispatch', 'Greetings::SayHello')

      expect(status).not_to be_success
      expect(out).to include('--name: is required')
    end

    def front_matter(skill) = YAML.safe_load(skill[/\A---\n(.*?)\n---\n/m, 1])

    it "installs Sidereal's skills with skills update, and links to them" do
      root = generate

      out, status = bin_sid(root, 'skills', 'update')

      expect(status).to be_success, out
      expect(out).to include('write   skills/sidereal-cli', 'link    .claude/skills -> ../skills')
      expect(Dir.children(File.join(root, 'skills'))).to eq(['sidereal-cli'])
      skill = read(root, 'skills/sidereal-cli/SKILL.md')
      expect(front_matter(skill)['name']).to eq('sidereal-cli')
      expect(skill).to include('bin/sid --help')
      %w[.claude/skills .agents/skills].each do |link|
        expect(File.readlink(File.join(root, link))).to eq('../skills')
        expect(File.file?(File.join(root, link, 'sidereal-cli/SKILL.md'))).to be(true), link
      end
    end

    it "installs the skills of the integrations the app requires, keeping the app's own" do
      root = generate('app', '--sourced')
      FileUtils.mkdir_p(File.join(root, 'skills/my-skill'))
      File.write(File.join(root, 'skills/my-skill/SKILL.md'), 'mine')
      FileUtils.mkdir_p(File.join(root, 'skills/sidereal-cli'))
      File.write(File.join(root, 'skills/sidereal-cli/SKILL.md'), 'edited')

      out, status = bin_sid(root, 'skills', 'update')

      expect(status).to be_success, out
      expect(out).to include('write   skills/sidereal-cli', 'write   skills/sidereal-sourced')
      expect(front_matter(read(root, 'skills/sidereal-cli/SKILL.md'))['name']).to eq('sidereal-cli')
      skill = read(root, 'skills/sidereal-sourced/SKILL.md')
      expect(front_matter(skill)['name']).to eq('sidereal-sourced')
      expect(skill).to include('bin/sid sourced --help', 'bin/sid sourced topology --schemas')
      expect(read(root, 'skills/my-skill/SKILL.md')).to eq('mine')
    end

    it 'lists commands handled by Sourced deciders' do
      root = generate('app', '--sourced')
      File.write(File.join(root, 'system/todos.rb'), <<~RUBY)
        class Todos < Sourced::Decider
          partition_by :title

          AddTodo = Sourced::Command.define('app.todos.add') do
            attribute :title, String
          end

          TodoAdded = Sourced::Event.define('app.todos.added') do
            attribute :title, String
          end

          command AddTodo do |_state, cmd|
            event TodoAdded, title: cmd.payload.title
          end
        end
      RUBY
      File.write(File.join(root, 'boot.rb'), "Sourced.register(Todos)\n", mode: 'a')

      out, status = bin_sid(root, 'commands', 'list')

      expect(status).to be_success, out
      expect(out).to match(/^app\.greetings\.say_hello\s+Greetings::SayHello\s+App::Commander\s+yes$/)
      expect(out).to match(/^app\.todos\.add\s+Todos::AddTodo\s+Todos$/)

      out, status = bin_sid(root, 'commands', 'info', 'Todos::AddTodo')

      expect(status).to be_success, out
      expect(out).to match(/^Handled by\s+Todos$/)
      expect(out).to match(/^title\s+string\s+yes$/)

      out, status = bin_sid(root, 'sourced', 'topology')

      expect(status).to be_success, out
      expect(out).to include("command app.todos.add  Todos::AddTodo\n└─ event app.todos.added  Todos::TodoAdded")

      out, status = bin_sid(root, 'sourced', 'topology', '--schemas')

      expect(status).to be_success, out
      schema_line = out.lines.find { |line| line.start_with?('│  schema ') }
      expect(JSON.parse(schema_line.delete_prefix('│  schema '))).to include('required' => ['title'])
    end
  end

  describe 'usage and errors' do
    it 'prints usage with --help' do
      result = nil

      expect { result = sid_new('--help') }.to output(/Create a new Sidereal app/).to_stdout
      expect(result).to be(true)
    end

    it 'fails without a name' do
      expect(sid_new).to be(false)
      expect(io.string).to include('Name the new app')
    end

    it 'fails for a name that is not a valid Ruby identifier' do
      expect(sid_new(File.join(@dir, 'My-App'), '--skip-bundle')).to be(false)
      expect(io.string).to include(%("My-App" isn't a valid app name))
      expect(Dir.exist?(File.join(@dir, 'My-App'))).to be(false)
    end

    it 'refuses to write into a non-empty directory' do
      root = File.join(@dir, 'app')
      FileUtils.mkdir_p(root)
      File.write(File.join(root, 'keep.txt'), 'mine')

      expect(sid_new(root, '--skip-bundle')).to be(false)
      expect(io.string).to include("already exists and isn't empty")
      expect(Dir.children(root)).to eq(['keep.txt'])
    end

    it 'writes into a non-empty directory with --force' do
      root = File.join(@dir, 'app')
      FileUtils.mkdir_p(root)
      File.write(File.join(root, 'keep.txt'), 'mine')

      generate('app', '--force')

      expect(File.exist?(File.join(root, 'web/app.rb'))).to be(true)
      expect(read(root, 'keep.txt')).to eq('mine')
    end
  end
end
