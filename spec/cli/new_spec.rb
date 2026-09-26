# frozen_string_literal: true

require 'tmpdir'
require 'stringio'
require 'open3'
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
    it 'uses the file system backend' do
      boot = read(generate, 'boot.rb')

      expect(boot).to include('config.use_file_system!')
      expect(boot).not_to include('Integrations::Sourced')
    end

    it 'adds the Sourced integration with --sourced' do
      boot = read(generate('app', '--sourced'), 'boot.rb')

      expect(boot).to include("require 'sidereal/integrations/sourced'")
      expect(boot).to include('config.use Sidereal::Integrations::Sourced')
      expect(boot).to include("storage/app.db")
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

    it 'starts a console with the app loaded, from any directory' do
      root = generate

      out, status = bin_sid(root, 'console', stdin_data: "puts App.name, UI::WelcomePage.name, Dir.pwd\n",
        chdir: File.join(root, 'web'))

      expect(status).to be_success, out
      expect(out).to include("App\nUI::WelcomePage\n#{File.realpath(root)}\n")
    end
  end

  describe 'usage and errors' do
    it 'prints usage with --help' do
      expect(sid_new('--help')).to be(true)
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
