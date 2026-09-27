# frozen_string_literal: true

require 'fileutils'

module Sidereal
  # Agent skills that Sidereal and its integrations provide to apps, by
  # name. {#install} writes them into an app's skills/ directory, where
  # agents find them through the .claude/skills and .agents/skills links.
  # `bin/sid skills update` installs {Sidereal.skills}.
  #
  #   Sidereal.skills.add('my-skill', File.expand_path('skills/my-skill', __dir__))
  class Skills
    NAME_FORMAT = /\A[a-z0-9]+(-[a-z0-9]+)*\z/
    SKILL_FILE = 'SKILL.md'

    # Claude Code finds skills in .claude/skills and other agents look in
    # .agents/skills, so both link to the app's skills/ directory.
    LINKS = {
      '.claude/skills' => '../skills',
      '.agents/skills' => '../skills'
    }.freeze

    include Enumerable

    def initialize
      @paths = {}
    end

    def initialize_dup(source)
      super
      @paths = @paths.dup
    end

    # Register a skill. Adding a name again replaces its path, so an
    # integration can override a skill.
    #
    # @param name [String] lowercase words joined by hyphens, e.g. sidereal-cli
    # @param path [String] the skill's SKILL.md, or a directory holding it
    #   and any files it refers to
    # @return [self]
    # @raise [ArgumentError] for a bad name or a path with no SKILL.md
    def add(name, path)
      raise ArgumentError, "#{name.inspect} isn't a valid skill name, e.g. my-skill" unless NAME_FORMAT.match?(name)

      path = File.expand_path(path)
      skill_file = File.directory?(path) ? File.join(path, SKILL_FILE) : path
      raise ArgumentError, "No #{SKILL_FILE} at #{path}" unless File.basename(skill_file) == SKILL_FILE && File.file?(skill_file)

      @paths[name] = path
      self
    end

    # Unregister a skill. Its files already in apps stay there.
    #
    # @return [self]
    def delete(name)
      @paths.delete(name)
      self
    end

    # @yieldparam name [String]
    # @yieldparam path [String] as given to {#add}, expanded
    def each(&) = @paths.each(&)

    # @return [String, nil] a skill's path
    def [](name) = @paths[name]

    # Write every skill into +root+/skills/<name>/, replacing what's there,
    # and create the {LINKS}. Other skills in skills/ are left alone.
    #
    # @param root [String] the app's root directory
    # @yieldparam action [Symbol] :write, :link or :skip
    # @yieldparam path [String] relative to +root+
    # @return [void]
    def install(root)
      each do |name, source|
        target = File.join(root, 'skills', name)
        FileUtils.rm_rf(target)
        FileUtils.mkdir_p(target)
        if File.directory?(source)
          FileUtils.cp_r(File.join(source, '.'), target)
        else
          FileUtils.cp(source, File.join(target, SKILL_FILE))
        end
        yield :write, "skills/#{name}" if block_given?
      end

      LINKS.each do |path, target|
        link = File.join(root, path)
        if File.symlink?(link) && File.readlink(link) == target
          next
        elsif File.exist?(link) && !File.symlink?(link)
          yield :skip, path if block_given?
          next
        end

        FileUtils.mkdir_p(File.dirname(link))
        FileUtils.rm_f(link)
        File.symlink(target, link)
        yield :link, path if block_given?
      end
    end
  end

  # Process-global skills registry. Sidereal registers its own skills here,
  # and each integration registers its skills when it's required, so an app
  # has the skills of the integrations its boot file requires.
  #
  # @return [Skills]
  def self.skills
    @skills ||= Skills.new
  end

  skills.add('sidereal-cli', File.expand_path('skills/sidereal-cli', __dir__))
end
