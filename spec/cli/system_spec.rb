# frozen_string_literal: true

require 'tmpdir'
require 'stringio'
require 'sidereal/cli'

RSpec.describe Sidereal::CLI::System do
  around do |example|
    pwd = Dir.pwd
    Dir.mktmpdir('sid-system') do |dir|
      @dir = dir
      example.run
    end
  ensure
    Dir.chdir(pwd)
  end

  after { %w[console commands db sourced system skills].each { |name| Sidereal::CLI.registry.delete(name) } }

  # Enough for CLI.load_app: it chdirs in and requires boot.rb.
  def app!(body)
    File.write(File.join(@dir, 'Gemfile'), "source 'https://rubygems.org'\n\ngem 'sidereal'\n")
    File.write(File.join(@dir, 'boot.rb'), "require 'sidereal'\n#{body}")
    Sidereal::CLI.load_app(@dir)
    @dir
  end

  def sid(*arguments)
    out = StringIO.new
    Sidereal::CLI::Application.new(arguments, name: 'sid', output: out).call
    out.string
  end

  describe 'graph' do
    it 'lists the components in dependency order, with what each needs' do
      app!(<<~'RUBY')
        Sidereal.config.declare('url', String) { 'postgres://' }
        Sidereal.config.declare('conn', String)
        Sidereal.config.config!('conn', ['url']) { |url| "conn:#{url}" }
      RUBY

      out = sid('system', 'graph')

      expect(out).to include('url', 'conn', 'needs', 'String')
      # A dependency is listed before the component that needs it.
      expect(out.index("\nurl")).to be < out.index("\nconn")
      expect(out).to match(/conn.*\n\s+needs\s+url/)
    end

    it 'counts the components and names the lifecycle state' do
      app!("Sidereal.config.declare('thing', String) { 'x' }\n")

      expect(sid('system', 'graph')).to match(/Sidereal\.config\s+\d+ components, built/)
    end

    it 'marks a deferred component' do
      app!("Sidereal.config.declare('worker', String) { 'w' }\nSidereal.config.defer('worker')\n")

      expect(sid('system', 'graph')).to match(/worker.*deferred/)
    end

    it 'marks a mode that is not the default singleton' do
      app!(<<~RUBY)
        Sidereal.config.declare('now', String)
        Sidereal.config.config('now') { 'tick' }
      RUBY

      expect(sid('system', 'graph')).to match(/now.*dynamic/)
    end

    it 'shows what depends on each component with --dependents' do
      app!(<<~'RUBY')
        Sidereal.config.declare('url', String) { 'postgres://' }
        Sidereal.config.declare('conn', String)
        Sidereal.config.config!('conn', ['url']) { |url| "conn:#{url}" }
      RUBY

      out = sid('system', 'graph', '--dependents')

      expect(out).to match(/url.*\n\s+used by\s+conn/)
      expect(out).not_to include('needs')
    end

    # Building raises on a configuration like this, so the command reports the
    # problem under the graph instead of failing — which is when you most want
    # to see the shape of things.
    it 'still prints the graph when a component is declared but not implemented' do
      app!(<<~RUBY)
        Sidereal.config.declare('ok', String) { 'fine' }
        Sidereal.config.declare('orphan', String)
      RUBY

      out = sid('system', 'graph')

      expect(out).to include('orphan', 'unimplemented')
      expect(out).to include('UnimplementedComponentError')
      expect(out).to include('ok')
    end

    it 'names a dependency that was never declared' do
      app!(<<~RUBY)
        Sidereal.config.declare('conn', String)
        Sidereal.config.config!('conn', ['nowhere']) { |x| x }
      RUBY

      out = sid('system', 'graph')

      expect(out).to include('Not declared: ', 'nowhere')
    end

    describe '--mermaid' do
      it 'prints the flowchart and nothing else, so it can be redirected to a file' do
        app!(<<~'RUBY')
          Sidereal.config.declare('url', String) { 'postgres://' }
          Sidereal.config.declare('conn', String)
          Sidereal.config.config!('conn', ['url']) { |url| "conn:#{url}" }
        RUBY

        out = sid('system', 'graph', '--mermaid')

        expect(out).to start_with('flowchart LR')
        expect(out).to include('url', 'conn', '-->')
        # None of the human-readable rendering leaks in.
        expect(out).not_to include('Sidereal.config', 'components,', 'needs')
      end

      it 'keeps a configuration problem off stdout, so the redirect stays clean' do
        app!(<<~'RUBY')
          Sidereal.config.declare('ok', String) { 'fine' }
          Sidereal.config.declare('orphan', String)
        RUBY

        expect { @out = sid('system', 'graph', '--mermaid') }
          .to output(/UnimplementedComponentError.*orphan/).to_stderr

        expect(@out).to start_with('flowchart LR')
        expect(@out).not_to include('UnimplementedComponentError')
      end
    end

    it 'is available without an app having configured anything' do
      expect(described_class::COMMANDS).to include('graph' => Sidereal::CLI::System::Graph)
    end
  end

  describe 'tree' do
    it 'nests components under the namespaces that hold them' do
      app!(<<~'RUBY')
        Sidereal.config.declare('mailer.url', String) { 'smtp://' }
      RUBY

      out = sid('system', 'tree')

      expect(out).to include('(root)', 'mailer', 'url')
      # The namespace is a heading; the component hangs off it.
      expect(out).to match(/mailer\n.*└── url String/)
    end

    it "marks a mounted component's own subtree" do
      app!('')

      expect(sid('system', 'tree')).to include('sidereal [mounted]')
    end

    # The question the tree answers that the graph doesn't: who implemented
    # what a library declared.
    it 'says when a component was implemented by someone other than its owner' do
      app!("Sidereal.config.config!('sidereal.workers.count') { 4 }\n")

      expect(sid('system', 'tree')).to match(/count .*implemented by \(root\)/)
    end

    it 'marks a deferred component and an unimplemented one' do
      app!("Sidereal.config.declare('orphan', String)\n")

      out = sid('system', 'tree')

      expect(out).to include('orphan String (not implemented, open)')
      expect(out).to match(/dispatcher .*deferred/)
      expect(out).to include('UnimplementedComponentError')
    end

    it 'counts the components, not the namespaces that hold them' do
      app!('')

      tree = sid('system', 'tree')[/(\d+) components/, 1].to_i
      graph = sid('system', 'graph')[/(\d+) components/, 1].to_i

      expect(tree).to eq(graph)
    end

    describe '--mermaid' do
      it 'prints the flowchart and nothing else' do
        app!('')

        out = sid('system', 'tree', '--mermaid')

        expect(out).to start_with('flowchart TD')
        expect(out).not_to include('Sidereal.config', 'components,', '├──')
      end

      it 'keeps a configuration problem off stdout' do
        app!("Sidereal.config.declare('orphan', String)\n")

        expect { @out = sid('system', 'tree', '--mermaid') }
          .to output(/UnimplementedComponentError/).to_stderr

        expect(@out).to start_with('flowchart TD')
        expect(@out).not_to include('UnimplementedComponentError')
      end
    end
  end

  describe 'the namespace' do
    it 'prints usage when no sub-command is given' do
      app!('')

      expect(sid('system')).to include('graph', 'tree', 'Print the app components')
    end
  end
end
