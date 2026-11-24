# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

# A temporary directory for each example, and +write+ to put files in it, for
# specs that register assets from disk. Include it in a group with
# +include_context 'tmp files'+.
RSpec.shared_context 'tmp files' do
  around do |example|
    Dir.mktmpdir('sidereal-spec') do |dir|
      @tmp_dir = dir
      example.run
    end
  end

  # The example's directory.
  def tmp_dir = @tmp_dir

  # Write a file under the example's directory, and return its path.
  def write(relative, content)
    path = File.join(tmp_dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    # A later write in the same example must show as a change to the mtime.
    File.utime(Time.now + (@writes = (@writes || 0) + 1), Time.now + @writes, path)
    path
  end
end
