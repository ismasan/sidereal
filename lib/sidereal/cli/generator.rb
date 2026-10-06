# frozen_string_literal: true

require 'erb'
require 'fileutils'

module Sidereal
  module CLI
    # Renders a directory of templates into a target directory.
    #
    # Every file under +source+ is copied to the same relative path under
    # +target+. Files ending in +.erb+ are rendered with ERB against +context+
    # and written without the extension. A path segment starting with +dot_+
    # is written as a dotfile (+dot_gitignore+ becomes +.gitignore+), so
    # templates never act as dotfiles inside the Sidereal repository itself.
    # Written files keep their template's permissions, so an executable
    # template (a binstub) generates an executable file.
    #
    # An +.erb+ template that renders to nothing writes no file, which is how a
    # template is made conditional: wrap the whole of it in an +<% if %>+ on
    # the context. A blank file that is wanted isn't a template, so it is
    # written as it is (+storage/dot_keep+).
    class Generator
      DOT_PREFIX = /\Adot_/
      ERB_EXT = '.erb'

      # @param source [String] template directory
      # @param target [String] directory to write into
      # @param context [Object] ERB templates are evaluated against this object,
      #   so its public methods are available inside them
      def initialize(source, target, context)
        @source = source
        @target = target
        @context = context
      end

      # Write every template into the target directory.
      #
      # @yieldparam path [String] each written path, relative to the target
      # @return [Array<String>] written paths, relative to the target
      def generate
        templates.filter_map do |template|
          content = render(template)
          next if content.nil?

          path = output_path(template)
          destination = File.join(@target, path)
          FileUtils.mkdir_p(File.dirname(destination))
          File.write(destination, content)
          File.chmod(File.stat(File.join(@source, template)).mode, destination)
          yield path if block_given?
          path
        end
      end

      private

      def templates
        Dir.glob('**/*', File::FNM_DOTMATCH, base: @source)
          .reject { |path| File.directory?(File.join(@source, path)) }
          .sort
      end

      def output_path(template)
        template
          .delete_suffix(ERB_EXT)
          .split('/')
          .map { |segment| segment.sub(DOT_PREFIX, '.') }
          .join('/')
      end

      # The file's contents, or nil for an ERB template that renders to
      # nothing: see {Generator} on conditional templates.
      def render(template)
        source = File.read(File.join(@source, template))
        return source unless template.end_with?(ERB_EXT)

        rendered = ERB.new(source, trim_mode: '-').result(@context.instance_eval { binding })
        rendered unless rendered.strip.empty?
      end
    end
  end
end
