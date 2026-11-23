# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::KeyGenerator do
  subject(:keys) { described_class.new('m' * 64) }

  describe '#derive' do
    it 'derives a 64-byte binary key for each purpose' do
      key = keys.derive('session')

      expect(key.bytesize).to eq(64)
      expect(key.encoding).to eq(Encoding::BINARY)
      expect(keys.derive('sidereal.signer')).not_to eq(key)
    end

    it 'derives the same key from the same secret and purpose' do
      expect(described_class.new('m' * 64).derive('session')).to eq(keys.derive('session'))
      expect(described_class.new('n' * 64).derive('session')).not_to eq(keys.derive('session'))
    end

    it 'derives keys of any length' do
      expect(keys.derive('session', length: 32).bytesize).to eq(32)
    end

    it 'derives keys a Sidereal::Signer and Rack sessions accept' do
      expect { Sidereal::Signer.new(keys.derive('sidereal.signer')) }.not_to raise_error
      expect { Rack::Session::Cookie.new(->(_) {}, secret: keys.derive('session')) }.not_to raise_error
    end
  end

  it 'refuses a secret shorter than 64 bytes' do
    expect { described_class.new('m' * 63) }.to raise_error(ArgumentError, 'master secret must be at least 64 bytes')
  end

  it 'leaves the secret out of #inspect' do
    expect(keys.inspect).to eq('#<Sidereal::KeyGenerator>')
  end

  describe '.file_secret' do
    around do |example|
      Dir.mktmpdir { |dir| @dir = dir; example.run }
    end

    let(:path) { File.join(@dir, 'storage', 'secret.txt') }

    it 'creates the file with a new secret, readable only by its owner, and its directory' do
      secret = described_class.file_secret(path)

      expect(secret).to match(/\A\h{64}\z/)
      expect(File.read(path)).to eq(secret)
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(Dir.children(File.dirname(path))).to eq(['secret.txt'])
    end

    it 'reads the secret the file already has' do
      first = described_class.file_secret(path)

      expect(described_class.file_secret(path)).to eq(first)
      File.write(path, "#{'x' * 64}\n")
      expect(described_class.file_secret(path)).to eq('x' * 64)
    end

    it 'creates the file on a filesystem without hard links' do
      allow(File).to receive(:link).and_raise(Errno::EPERM)

      secret = described_class.file_secret(path)

      expect(File.read(path)).to eq(secret)
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(Dir.children(File.dirname(path))).to eq(['secret.txt'])
      expect(described_class.file_secret(path)).to eq(secret)
    end

    it 'waits for a file another process has created but not yet written' do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '')
      writer = Thread.new do
        sleep 0.05
        File.write(path, 'w' * 64)
      end

      expect(described_class.file_secret(path)).to eq('w' * 64)
    ensure
      writer&.join
    end

    it 'gives processes that create it at once the same secret, without hard links too' do
      allow(File).to receive(:link).and_raise(Errno::ENOTSUP)

      expect(secrets_of_processes_creating(path).uniq).to eq([File.read(path)])
    end

    # Forks 8 processes that each read the secret at +path+, creating it if
    # it's missing, and returns what each read.
    def secrets_of_processes_creating(path)
      readers = Array.new(8) do
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          writer.write(described_class.file_secret(path))
          writer.close
          exit!(0)
        end
        writer.close
        [pid, reader]
      end
      readers.map do |pid, reader|
        Process.wait(pid)
        reader.read.tap { reader.close }
      end
    end

    it 'gives processes that create it at once the same secret' do
      expect(secrets_of_processes_creating(path).uniq).to eq([File.read(path)])
      expect(Dir.children(File.dirname(path))).to eq(['secret.txt'])
    end
  end

  describe '.generate_secret' do
    it 'makes a secret long enough to derive from, different each time' do
      secret = described_class.generate_secret

      expect(secret).to match(/\A\h{64}\z/)
      expect { described_class.new(secret) }.not_to raise_error
      expect(described_class.generate_secret).not_to eq(secret)
    end
  end
end
