# frozen_string_literal: true

require 'tmpdir'
require 'sidereal/cli'

RSpec.describe Sidereal::CLI::Generator do
  around do |example|
    Dir.mktmpdir do |dir|
      @source = File.join(dir, 'source')
      @target = File.join(dir, 'target')
      example.run
    end
  end

  def template(path, content)
    File.join(@source, path).tap do |file|
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, content)
    end
  end

  let(:context) { Data.define(:name).new(name: 'World') }

  it 'renders .erb templates against the context and drops the extension' do
    template('greeting.txt.erb', "Hello, <%= name %>!\n<% if false -%>\nhidden\n<% end -%>\n")

    Sidereal::CLI::Generator.new(@source, @target, context).generate

    expect(File.read(File.join(@target, 'greeting.txt'))).to eq("Hello, World!\n")
  end

  it 'copies other files as they are' do
    template('public/app.css', 'body { content: "<%= name %>"; }')

    Sidereal::CLI::Generator.new(@source, @target, context).generate

    expect(File.read(File.join(@target, 'public/app.css'))).to eq('body { content: "<%= name %>"; }')
  end

  it 'writes dot_ path segments as dotfiles' do
    template('dot_gitignore', "/storage\n")
    template('storage/dot_keep', '')

    paths = Sidereal::CLI::Generator.new(@source, @target, context).generate

    expect(paths).to contain_exactly('.gitignore', 'storage/.keep')
    expect(File.exist?(File.join(@target, '.gitignore'))).to be(true)
    expect(File.exist?(File.join(@target, 'storage/.keep'))).to be(true)
  end

  it 'yields each written path' do
    template('a.txt', 'a')
    template('b/c.txt.erb', 'c')

    yielded = []
    Sidereal::CLI::Generator.new(@source, @target, context).generate { |path| yielded << path }

    expect(yielded).to eq(['a.txt', 'b/c.txt'])
  end
end
