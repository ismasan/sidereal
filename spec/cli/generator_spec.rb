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

  it 'writes no file for an erb template that renders to nothing' do
    template('conditional.rb.erb', "<% if false -%>\nnothing\n<% end -%>\n")
    template('empty.keep', '')

    paths = Sidereal::CLI::Generator.new(@source, @target, context).generate

    expect(paths).to eq(['empty.keep'])
    expect(File.exist?(File.join(@target, 'conditional.rb'))).to be(false)
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

  it 'keeps template permissions' do
    File.chmod(0o755, template('bin/run.erb', '#!/usr/bin/env ruby'))
    File.chmod(0o644, template('notes.txt', 'notes'))

    Sidereal::CLI::Generator.new(@source, @target, context).generate

    expect(File.stat(File.join(@target, 'bin/run')).mode & 0o777).to eq(0o755)
    expect(File.stat(File.join(@target, 'notes.txt')).mode & 0o777).to eq(0o644)
  end

  it 'yields each written path' do
    template('a.txt', 'a')
    template('b/c.txt.erb', 'c')

    yielded = []
    Sidereal::CLI::Generator.new(@source, @target, context).generate { |action, path| yielded << [action, path] }

    expect(yielded).to eq([[:create, 'a.txt'], [:create, 'b/c.txt']])
  end

  describe 'overwrite: false' do
    it 'keeps a file that already exists, and says it skipped it' do
      template('keep.txt', 'from the template')
      FileUtils.mkdir_p(@target)
      File.write(File.join(@target, 'keep.txt'), 'edited by hand')
      template('fresh.txt', 'new')

      yielded = []
      written = Sidereal::CLI::Generator.new(@source, @target, context)
                                       .generate(overwrite: false) { |action, path| yielded << [action, path] }

      expect(yielded).to contain_exactly([:skip, 'keep.txt'], [:create, 'fresh.txt'])
      expect(written).to eq(['fresh.txt'])
      expect(File.read(File.join(@target, 'keep.txt'))).to eq('edited by hand')
    end
  end
end
