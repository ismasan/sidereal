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
      config/components/secrets.rb
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

    # Its own command, so an app gets the same install whenever it is run.
    # After `bundle install`, since bin/sid needs the app's bundle.
    it 'installs the database with --db, once the bundle is there' do
      expect(commands_run('--db'))
        .to eq([%w[bundle install], %w[bin/sid db install], %w[bin/sid skills update]])
    end

    # Not `db install`: Sourced keeps its messages in the app's database, so
    # `sourced install` asks for one itself rather than `new` knowing it must.
    it 'installs Sourced with --sourced, which installs the database itself' do
      expect(commands_run('--sourced'))
        .to eq([%w[bundle install], %w[bin/sid sourced install], %w[bin/sid skills update]])
    end

    it "doesn't install skills with --no-skills" do
      expect(commands_run('--no-skills')).to eq([%w[bundle install]])
    end

    it 'says to install the database with --db --skip-bundle' do
      expect { sid_new(File.join(@dir, 'app'), '--db', '--skip-bundle') }
        .to output(%r{bundle install\n\s+bin/sid db install\n}).to_stdout
    end

    it 'says to install skills with --skip-bundle' do
      expect { sid_new(File.join(@dir, 'app'), '--skip-bundle') }.to output(%r{bundle install\n\s+bin/sid skills update\n}).to_stdout
    end

    it "doesn't mention skills with --skip-bundle --no-skills" do
      expect { sid_new(File.join(@dir, 'app'), '--skip-bundle', '--no-skills') }.not_to output(/skills/).to_stdout
    end
  end

  describe 'secret' do
    it 'loads .env in boot.rb, before Sidereal is configured, and git ignores it' do
      root = generate
      boot = read(root, 'boot.rb')

      expect(boot).to include("require 'dotenv'", "Dotenv.load(File.expand_path('.env', __dir__))")
      expect(boot.index('Dotenv.load')).to be < boot.index('Sidereal.config')
      expect(read(root, '.gitignore').lines).to include("/.env\n")
    end

    # Runs Ruby in the generated app, with no SIDEREAL_SECRET of the specs'
    # own unless +env+ gives one.
    def run_in_app(root, script, env = {})
      Open3.capture2e({ 'SIDEREAL_SECRET' => nil }.merge(env), RbConfig.ruby, '-e', script, chdir: root)
    end

    # Prints whether the app's signer verifies a token signed with the key
    # +secret+ derives for it.
    def verifies_signed_with(secret)
      <<~RUBY
        require_relative 'boot'
        Sidereal.config.build!
        key = Sidereal::KeyGenerator.new(#{secret}).derive('sidereal.signer')
        token = Sidereal::Signer.new(key).generate('hi', purpose: 'test')
        puts Sidereal.signer.class, Sidereal.signer.verify(token, purpose: 'test').inspect
      RUBY
    end

    def file_secret = "File.read('storage/secret.txt')"

    it 'creates a secret in storage/ on first boot, which git ignores, and reuses it' do
      root = generate
      expect(File.exist?(File.join(root, 'storage/secret.txt'))).to be(false)

      out, status = run_in_app(root, verifies_signed_with(file_secret))
      expect(status).to be_success, out
      expect(out.lines.last(2)).to eq(["Sidereal::Signer\n", "\"hi\"\n"])

      secret = read(root, 'storage/secret.txt')
      expect(secret).to match(/\A\h{64}\z/)
      expect(File.stat(File.join(root, 'storage/secret.txt')).mode & 0o777).to eq(0o600)
      expect(read(root, '.gitignore').lines).to include("/storage/*\n")

      out, status = run_in_app(root, verifies_signed_with(file_secret))
      expect(status).to be_success, out
      expect(read(root, 'storage/secret.txt')).to eq(secret)
    end

    it 'uses SIDEREAL_SECRET instead when it is set, and refuses a short one without showing it' do
      root = generate
      env = { 'SIDEREAL_SECRET' => 'e' * 64 }

      out, status = run_in_app(root, verifies_signed_with("'e' * 64"), env)
      expect(status).to be_success, out
      expect(out.lines.last).to eq("\"hi\"\n")
      expect(File.exist?(File.join(root, 'storage/secret.txt'))).to be(false)

      out, status = run_in_app(root, verifies_signed_with("'e' * 64"), { 'SIDEREAL_SECRET' => 'e' * 63 })
      expect(status).not_to be_success
      expect(out).to include('sidereal.secret_key_base: must have attribute bytesize === 64..')
      expect(out).not_to include('e' * 63)
    end

    it "configures Sidereal's master secret in config/components/secrets.rb, and leaves the signer to Sidereal" do
      root = generate

      expect(read(root, 'config/components/secrets.rb')).to include(
        "Sidereal.config.config!('sidereal.secret_key_base') do",
        "Sidereal::KeyGenerator.file_secret(secret_file)"
      )
      expect(File.exist?(File.join(root, 'config/components/signer.rb'))).to be(false)
    end

    it 'lets the app read the master secret from elsewhere, ex. a vault' do
      root = generate
      File.write(File.join(root, 'config/components/secrets.rb'), <<~RUBY)
        Sidereal.config.config!('sidereal.secret_key_base') { 'v' * 64 }
      RUBY

      out, status = run_in_app(root, verifies_signed_with("'v' * 64"))
      expect(status).to be_success, out
      expect(out.lines.last).to eq("\"hi\"\n")
      expect(File.exist?(File.join(root, 'storage/secret.txt'))).to be(false)
    end

    it 'lets the app replace sidereal.secrets with anything that derives keys' do
      root = generate
      File.write(File.join(root, 'config/components/secrets.rb'), <<~RUBY)
        Sidereal.config.config!('sidereal.secret_key_base') { 'unused' * 11 }
        Sidereal.config.config!('sidereal.secrets') { Sidereal::KeyGenerator.new('w' * 64) }
      RUBY

      out, status = run_in_app(root, verifies_signed_with("'w' * 64"))
      expect(status).to be_success, out
      expect(out.lines.last).to eq("\"hi\"\n")
    end

    it 'lets the app replace the signer with one that needs no key' do
      root = generate
      File.write(File.join(root, 'config/components/signer.rb'), <<~RUBY)
        Sidereal.config.config!('sidereal.signer') { Struct.new(:generate, :verify).new }
      RUBY

      out, status = run_in_app(root, "require_relative 'boot'; Sidereal.config.build!; puts Sidereal.signer.class.superclass")
      expect(status).to be_success, out
      expect(out.lines.last).to eq("Struct\n")
    end

    it 'signs session cookies with a key derived from the secret' do
      root = generate
      expect(read(root, 'web/app.rb')).to include("session secret: -> { Sidereal.secrets.derive('session') }")

      script = <<~RUBY
        require 'rack'
        app = Rack::Builder.parse_file('config.ru')
        Sidereal.config.build!
        cookie = Rack::MockRequest.new(app).get('/').headers['set-cookie'][/rack\\.session=[^;]+/]
        key = Sidereal::KeyGenerator.new(#{file_secret}).derive('session')
        reader = Rack::Session::Cookie.new(->(env) { [200, {}, [env['rack.session'].to_h.keys.inspect]] }, secret: key)
        puts reader.call(Rack::MockRequest.env_for('/', 'HTTP_COOKIE' => cookie))[2].first
      RUBY
      out, status = run_in_app(root, script)
      expect(status).to be_success, out
      expect(out.lines.last).to include('sidereal.session')
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

    it 'includes Falcon, Zeitwerk and dotenv, and nothing optional' do
      gemfile = read(generate, 'Gemfile')

      expect(gemfile).to include("gem 'falcon'", "gem 'zeitwerk'", "gem 'dotenv'")
      expect(gemfile).not_to include('rspec')
      expect(gemfile).not_to include('sourced')
    end

    it 'adds RSpec with --rspec' do
      expect(read(generate('app', '--rspec'), 'Gemfile')).to include("group :test do\n  gem 'rspec'\nend")
    end

    # `sourced install` adds the sourced gem, and the `db install` it runs
    # adds sequel and sqlite3 — so the Gemfile template knows about none of them.
    it 'leaves the Sourced and database gems to their installs' do
      gemfile = read(generate('app', '--sourced', '--db'), 'Gemfile')

      expect(gemfile).not_to include('sourced')
      expect(gemfile).not_to include('sequel')
      expect(gemfile).not_to include('sqlite3')
    end
  end

  describe 'README' do
    it 'tells a plain app to bundle and run' do
      readme = read(generate, 'README.md')

      expect(readme).not_to include('db migrations run')
      expect(readme).not_to include('## Database')
    end

    # storage/ is gitignored and db/migrations/ is not, so a clone rebuilds its
    # database from the migrations — and with Sourced it can't boot without them.
    it 'tells an app with a database to migrate first' do
      %w[--db --sourced].each do |option|
        readme = read(generate(option.delete_prefix('--'), option), 'README.md')

        expect(readme).to include('bin/sid db migrations run', 'db/migrations/` are committed')
        expect(readme).to include('| `db/migrations/` |', '## Database')
      end
    end

    it 'points a Sourced app at its topology' do
      expect(read(generate('app', '--sourced'), 'README.md')).to include('bin/sid sourced topology')
    end
  end

  describe 'boot.rb' do
    # Load-bearing: both `use_file_system!` and the `use` in a generated
    # config/components/sourced.rb implement `sidereal.store`, and the last
    # implementation of a key wins. The other order leaves a Sourced app
    # appending commands to files.
    it 'loads config/components after configuring Sidereal, so a file there can replace one of its own' do
      boot = read(generate, 'boot.rb')

      expect(boot).to include("Dir[File.join(__dir__, 'config/components/**/*.rb')].sort.each { |file| require file }")
      expect(boot.index('config/components/**')).to be > boot.index('Sidereal.config.use_file_system!')
    end

    # Also load-bearing: `sourced install` writes a component file that
    # requires Sourced, and classes in system/ subclass Sourced::Decider. The
    # other order fails with `uninitialized constant Sourced::Decider`.
    it 'eager loads the app after the components, so a component file can require what the classes need' do
      boot = read(generate, 'boot.rb')

      expect(boot.index('LOADER.eager_load')).to be > boot.index('config/components/**')
    end

    # system/ components are declared after config/components, whose
    # components they may inject (and which may require the libraries they
    # subclass), and before eager_load, whose classes may inject them.
    it 'declares the system/ components between config/components and eager loading' do
      boot = read(generate, 'boot.rb')

      expect(boot).to include('Sidereal.config.loader = LOADER', "Sidereal.config.from_dir(File.expand_path('system/**/*.rb', __dir__)")
      expect(boot.index('Sidereal.config.install_dirs!')).to be > boot.index('config/components/**')
      expect(boot.index('LOADER.eager_load')).to be > boot.index('Sidereal.config.install_dirs!')
    end

    it 'leaves requiring the integration to `sourced install` as well' do
      expect(read(generate('app', '--sourced'), 'boot.rb')).not_to include('integrations/sourced')
    end

    it 'comes with an example component file, all commented out' do
      example = read(generate('app', '--sourced'), 'config/components/example.rb')
      code = example.lines.reject { |line| line.strip.empty? || line.start_with?('#') }

      expect(code).to eq([])
      expect(example).to include("declare('mailer'", "component!('mailer')", "config!('sidereal.workers.count')", 'dep :mailer')
      expect(read(generate('plain'), 'config/components/example.rb')).not_to include('Sourced deciders')
    end

    it 'uses the file system backend' do
      boot = read(generate, 'boot.rb')

      expect(boot).to include('Sidereal.config.use_file_system!')
      expect(boot).not_to include('Integrations::Sourced')
    end

    # Nothing generates a db component: `bin/sid db install` is the one thing
    # that sets a database up, whichever option asked for it.
    it 'always leaves the db component to `db install`' do
      %w[--db --sourced].each do |option|
        expect(files(generate(option.delete_prefix('--'), option))).not_to include('config/components/db.rb')
      end
      expect(files(generate('plain'))).not_to include('config/components/db.rb')
    end

    it 'leaves the Sourced wiring to `sourced install`' do
      root = generate('app', '--sourced')

      # The Zeitwerk comment mentions Sourced deciders; the wiring is what matters.
      expect(read(root, 'boot.rb')).not_to include('Integrations::Sourced')
      expect(files(root)).not_to include('config/components/sourced.rb')
    end
  end

  describe 'generated app' do
    # Boots config.ru in a separate process (it configures process-global
    # Sidereal state), builds the components as a Falcon worker does, and
    # requests the welcome page. The response follows a marker on stderr,
    # after anything the app logged there.
    def get_root(root)
      script = <<~RUBY
        require 'rack'
        app = Rack::Builder.parse_file('config.ru')
        Sidereal.config.build!
        response = Rack::MockRequest.new(app).get('/')
        $stderr.print "\\0response\\0", response.status, "\\n", response.body
      RUBY
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-e', script, chdir: root)
      [stderr.split("\0response\0", 2).last, status]
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

    # The bare LoadError from the binstub says nothing about why.
    it "explains a bin/sid that the app's Sidereal does not have" do
      allow_any_instance_of(Sidereal::CLI::Installer).to receive(:run!) do |_, *command|
        raise Sidereal::CLI::Error, "`#{command.join(' ')}` failed" if command.first == 'bin/sid'

        true
      end

      expect { sid_new(File.join(@dir, 'app'), '--db') }.to output.to_stdout

      expect(io.string).to include('bin/sid db install', '--sidereal-path')
    end

    it 'says nothing extra when the app was generated against a checkout' do
      allow_any_instance_of(Sidereal::CLI::Installer).to receive(:run!) do |_, *command|
        raise Sidereal::CLI::Error, "`#{command.join(' ')}` failed" if command.first == 'bin/sid'

        true
      end

      expect { sid_new(File.join(@dir, 'app'), '--db', '--sidereal-path', @dir) }.to output.to_stdout

      expect(io.string).not_to include('--sidereal-path <path>')
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

    it 'lists the install commands, in an app that has installed nothing' do
      out, status = bin_sid(generate, '--help')

      expect(status).to be_success, out
      expect(out).to include('db', 'sourced', 'install')
    end

    # The failure this guards against is silent: if boot.rb loaded
    # config/components before `use_file_system!`, the file-system store would
    # be implemented last and win, and a Sourced app would append its commands
    # to files while Sourced's runtime watched its tables.
    it 'leaves the store as Sourced once the integration is installed' do
      root = generate('app', '--sourced')
      out, status = bin_sid(root, 'sourced', 'install', '--skip-bundle')
      expect(status).to be_success, out

      out, status = bin_sid(root, 'console', stdin_data: "puts Sidereal.config['sidereal.store'].class\n")

      expect(status).to be_success, out
      expect(out).to include('Sourced::Store')
    end

    it "adds an integration's own commands once the app has installed it" do
      root = generate('app', '--sourced')
      out, status = bin_sid(root, 'sourced', 'install', '--skip-bundle')
      expect(status).to be_success, out

      out, status = bin_sid(root, 'sourced', '--help')

      expect(status).to be_success, out
      expect(out).to include('topology', 'Print how commands, events, read models and automations connect')
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

    it 'declares components from system/, which classes there and in web/ inject as they load' do
      root = generate
      FileUtils.mkdir_p(File.join(root, 'system/mailers'))
      File.write(File.join(root, 'system/mailers/templates.rb'), <<~RUBY)
        class Mailers::Templates
          include Sourced::Component::Installable

          def welcome = 'Welcome!'
        end
      RUBY
      # Injects a sibling, which loads after it
      File.write(File.join(root, 'system/mailers/client.rb'), <<~RUBY)
        class Mailers::Client
          include Sourced::Component::Installable
          extend Sidereal::Deps
          dep 'mailers.templates'

          def deliver = "sent: \#{templates.welcome}"
        end
      RUBY
      File.write(File.join(root, 'web/signup.rb'), <<~RUBY)
        class Signup
          extend Sidereal::Deps
          dep 'mailers.client'
        end
      RUBY

      out, status = bin_sid(root, 'console', stdin_data: "puts Signup.new.client.deliver\n",
        chdir: File.join(root, 'web'))

      expect(status).to be_success, out
      expect(out).to include('sent: Welcome!')
    end

    it 'declares components from system/ in a Sourced app' do
      root = generate('app', '--sourced')
      out, status = bin_sid(root, 'sourced', 'install', '--skip-bundle')
      expect(status).to be_success, out
      FileUtils.mkdir_p(File.join(root, 'system/clocks'))
      File.write(File.join(root, 'system/clocks/now.rb'), <<~RUBY)
        class Clocks::Now
          include Sourced::Component::Installable

          def call = 'tick'
        end
      RUBY


      out, status = bin_sid(root, 'console', stdin_data: "puts Sidereal.config['clocks.now'].call\n")

      expect(status).to be_success, out
      expect(out).to include('tick')
    end

    it 'registers the Sourced reactors in system/, which can inject system/ components and be components' do
      root = generate('app', '--sourced')
      out, status = bin_sid(root, 'sourced', 'install', '--skip-bundle')
      expect(status).to be_success, out
      FileUtils.mkdir_p(File.join(root, 'system/clocks'))
      File.write(File.join(root, 'system/clocks/now.rb'), <<~RUBY)
        class Clocks::Now
          include Sourced::Component::Installable

          def call = 'tick'
        end
      RUBY
      # Top level: a reactor, not a component. Injects a component from a
      # directory that loads after it.
      File.write(File.join(root, 'system/ledger.rb'), <<~RUBY)
        class Ledger < Sourced::Decider
          extend Sidereal::Deps
          dep 'clocks.now'

          Record = Sourced::Command.define('app.ledger.record') { attribute :entry_id, String }
          Recorded = Sourced::Event.define('app.ledger.recorded') { attribute :entry_id, String }

          partition_by :entry_id

          command Record => Recorded do |_state, cmd|
            event Recorded, entry_id: cmd.payload.entry_id
          end
        end
      RUBY
      # A base class, which handles no messages, and a reactor that's also a
      # component: the class itself, with a query method.
      File.write(File.join(root, 'system/application_decider.rb'), "class ApplicationDecider < Sourced::Decider; end\n")
      FileUtils.mkdir_p(File.join(root, 'system/catalog'))
      File.write(File.join(root, 'system/catalog/books.rb'), <<~RUBY)
        class Catalog::Books < ApplicationDecider
          Add = Sourced::Command.define('app.catalog.add') { attribute :book_id, String }
          Added = Sourced::Event.define('app.catalog.added') { attribute :book_id, String }

          partition_by :book_id

          def self.__install_component(c) = c.declare(Class).config { self }
          def self.titles = ['Dune']

          command Add => Added do |_state, cmd|
            event Added, book_id: cmd.payload.book_id
          end
        end
      RUBY
      File.write(File.join(root, 'web/shelf.rb'), <<~RUBY)
        class Shelf
          extend Sidereal::Deps
          dep 'catalog.books'
        end
      RUBY

      script = <<~RUBY
        puts Sidereal.config['sourced.router'].reactors.map(&:name).sort.join(',')
        puts Ledger.new.now.call
        puts Shelf.new.books.titles.join
      RUBY
      out, status = bin_sid(root, 'console', stdin_data: script)

      expect(status).to be_success, out
      expect(out.lines(chomp: true)).to include('App::Commander,Catalog::Books,Ledger', 'tick', 'Dune')
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
      expect(out).to include(
        'write   .agents/skills/sidereal-cli',
        'write   .agents/skills/sidereal-components',
        'link    .claude/skills -> ../.agents/skills'
      )
      expect(Dir.children(File.join(root, '.agents/skills')).sort).to eq(%w[sidereal-cli sidereal-components])
      expect(front_matter(read(root, '.agents/skills/sidereal-components/SKILL.md'))['name']).to eq('sidereal-components')
      skill = read(root, '.agents/skills/sidereal-cli/SKILL.md')
      expect(front_matter(skill)['name']).to eq('sidereal-cli')
      expect(skill).to include('bin/sid --help')
      expect(File.readlink(File.join(root, '.claude/skills'))).to eq('../.agents/skills')
      expect(File.file?(File.join(root, '.claude/skills/sidereal-cli/SKILL.md'))).to be(true)
    end

    it "installs the skills of the integrations the app configures, keeping the app's own" do
      root = generate('app', '--sourced')
      out, status = bin_sid(root, 'sourced', 'install', '--skip-bundle')
      expect(status).to be_success, out
      FileUtils.mkdir_p(File.join(root, '.agents/skills/my-skill'))
      File.write(File.join(root, '.agents/skills/my-skill/SKILL.md'), 'mine')
      FileUtils.mkdir_p(File.join(root, '.agents/skills/sidereal-cli'))
      File.write(File.join(root, '.agents/skills/sidereal-cli/SKILL.md'), 'edited')

      out, status = bin_sid(root, 'skills', 'update')

      expect(status).to be_success, out
      expect(out).to include('write   .agents/skills/sidereal-cli', 'write   .agents/skills/sidereal-sourced')
      expect(front_matter(read(root, '.agents/skills/sidereal-cli/SKILL.md'))['name']).to eq('sidereal-cli')
      skill = read(root, '.agents/skills/sidereal-sourced/SKILL.md')
      expect(front_matter(skill)['name']).to eq('sidereal-sourced')
      expect(skill).to include('bin/sid sourced --help', 'bin/sid sourced topology --schemas')
      expect(read(root, '.agents/skills/my-skill/SKILL.md')).to eq('mine')
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

          command AddTodo => TodoAdded do |_state, cmd|
            event TodoAdded, title: cmd.payload.title
          end
        end
      RUBY

      # `sourced install` configures the integration and installs the database
      # it needs; until then there is no `db` component to build.
      out, status = bin_sid(root, 'sourced', 'install', '--skip-bundle')
      expect(status).to be_success, out

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
