# frozen_string_literal: true

require 'tmpdir'
require 'sidereal/skills'

RSpec.describe Sidereal::Skills do
  subject(:skills) { described_class.new }

  around do |example|
    Dir.mktmpdir('skills') do |dir|
      @dir = dir
      example.run
    end
  end

  def skill_source(name, files = { 'SKILL.md' => "---\nname: #{name}\n---\n" })
    File.join(@dir, 'sources', name).tap do |path|
      files.each do |file, content|
        FileUtils.mkdir_p(File.dirname(File.join(path, file)))
        File.write(File.join(path, file), content)
      end
    end
  end

  def app_root = File.join(@dir, 'app').tap { |root| FileUtils.mkdir_p(root) }

  describe '#add' do
    it 'takes a SKILL.md file or a directory holding one' do
      source = skill_source('one')

      skills.add('one', File.join(source, 'SKILL.md')).add('two', source)

      expect(skills.to_a).to eq([['one', File.join(source, 'SKILL.md')], ['two', source]])
    end

    it 'rejects names that are not lowercase words joined by hyphens' do
      expect { skills.add('My_Skill', skill_source('x')) }.to raise_error(ArgumentError, /isn't a valid skill name/)
    end

    it 'rejects paths without a SKILL.md' do
      expect { skills.add('one', File.join(@dir, 'nope')) }.to raise_error(ArgumentError, /No SKILL.md/)
      expect { skills.add('one', skill_source('x', 'README.md' => 'x')) }.to raise_error(ArgumentError, /No SKILL.md/)
    end

    it 'replaces a skill added again under the same name' do
      skills.add('one', skill_source('a'))
      skills.add('one', skill_source('b'))

      expect(skills['one']).to eq(File.join(@dir, 'sources', 'b'))
    end
  end

  it 'deletes skills, and copies independently with dup' do
    skills.add('one', skill_source('one'))
    copy = skills.dup.add('two', skill_source('two'))

    skills.delete('one')

    expect(skills.map(&:first)).to eq([])
    expect(copy.map(&:first)).to eq(%w[one two])
  end

  describe '#install' do
    it "writes each skill into the app's skills/ directory, and links to it" do
      skills.add('file-skill', File.join(skill_source('file-skill'), 'SKILL.md'))
      skills.add('dir-skill', skill_source('dir-skill', 'SKILL.md' => 'dir', 'reference/notes.md' => 'notes'))
      root = app_root

      reported = []
      skills.install(root) { |action, path| reported << [action, path] }

      expect(File.read(File.join(root, 'skills/file-skill/SKILL.md'))).to eq("---\nname: file-skill\n---\n")
      expect(File.read(File.join(root, 'skills/dir-skill/reference/notes.md'))).to eq('notes')
      expect(File.readlink(File.join(root, '.claude/skills'))).to eq('../skills')
      expect(File.readlink(File.join(root, '.agents/skills'))).to eq('../skills')
      expect(reported).to eq([
        [:write, 'skills/file-skill'], [:write, 'skills/dir-skill'],
        [:link, '.claude/skills'], [:link, '.agents/skills']
      ])
    end

    it "replaces its skills' files, keeps other skills, and leaves correct links alone" do
      skills.add('one', skill_source('one'))
      root = app_root
      skills.install(root)
      File.write(File.join(root, 'skills/one/SKILL.md'), 'edited')
      File.write(File.join(root, 'skills/one/stale.md'), 'stale')
      FileUtils.mkdir_p(File.join(root, 'skills/mine'))
      File.write(File.join(root, 'skills/mine/SKILL.md'), 'mine')

      reported = []
      skills.install(root) { |action, path| reported << [action, path] }

      expect(Dir.children(File.join(root, 'skills/one'))).to eq(['SKILL.md'])
      expect(File.read(File.join(root, 'skills/one/SKILL.md'))).to eq("---\nname: one\n---\n")
      expect(File.read(File.join(root, 'skills/mine/SKILL.md'))).to eq('mine')
      expect(reported).to eq([[:write, 'skills/one']])
    end

    it 'skips a link whose place is taken by a real directory' do
      root = app_root
      FileUtils.mkdir_p(File.join(root, '.claude/skills'))

      reported = []
      skills.install(root) { |action, path| reported << [action, path] }

      expect(File.symlink?(File.join(root, '.claude/skills'))).to be(false)
      expect(reported).to eq([[:skip, '.claude/skills'], [:link, '.agents/skills']])
    end
  end
end

RSpec.describe Sidereal, '.skills' do
  it "has Sidereal's own skills" do
    expect(File.read(File.join(Sidereal.skills['sidereal-cli'], 'SKILL.md'))).to include('name: sidereal-cli')
  end
end
