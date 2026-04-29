# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::PubSub::Pattern do
  describe '.wildcard?' do
    it 'is true for `*` segments' do
      expect(described_class.wildcard?('donations.*')).to be true
    end

    it 'is true for `>` segments' do
      expect(described_class.wildcard?('donations.>')).to be true
    end

    it 'is false for plain names' do
      expect(described_class.wildcard?('donations.111')).to be false
    end

    it 'is false for the empty string' do
      expect(described_class.wildcard?('')).to be false
    end
  end

  describe '.compile' do
    it 'matches exact channel names' do
      re = described_class.compile('donations.111')
      expect(re.match?('donations.111')).to be true
      expect(re.match?('donations.222')).to be false
    end

    it 'compiles `*` to one non-empty segment' do
      re = described_class.compile('donations.*')
      expect(re.match?('donations.111')).to be true
      expect(re.match?('donations.111.created')).to be false
      expect(re.match?('donations.')).to be false
    end

    it 'compiles `>` to one or more segments' do
      re = described_class.compile('donations.>')
      expect(re.match?('donations.111')).to be true
      expect(re.match?('donations.111.created')).to be true
      expect(re.match?('donations')).to be false
    end

    it 'compiles a bare `>` to "everything"' do
      re = described_class.compile('>')
      expect(re.match?('a')).to be true
      expect(re.match?('a.b.c')).to be true
    end

    it 'escapes regex metacharacters in plain segments' do
      re = described_class.compile('a.b+c.d')
      expect(re.match?('a.b+c.d')).to be true
      expect(re.match?('a.bc.d')).to be false
    end
  end

  describe '.validate_subscription!' do
    it 'rejects empty pattern' do
      expect { described_class.validate_subscription!('') }.to raise_error(ArgumentError)
    end

    it 'rejects empty segments' do
      expect { described_class.validate_subscription!('a..b') }
        .to raise_error(ArgumentError, /empty segment/)
      expect { described_class.validate_subscription!('a.') }
        .to raise_error(ArgumentError, /empty segment/)
      expect { described_class.validate_subscription!('.a') }
        .to raise_error(ArgumentError, /empty segment/)
    end

    it 'rejects `>` in non-trailing position' do
      expect { described_class.validate_subscription!('a.>.c') }
        .to raise_error(ArgumentError, /must be the last segment/)
    end

    it 'allows `>` as the last segment' do
      expect { described_class.validate_subscription!('a.>') }.not_to raise_error
    end

    it 'allows `>` as the only segment' do
      expect { described_class.validate_subscription!('>') }.not_to raise_error
    end
  end

  describe '.validate_publish!' do
    it 'rejects empty channel name' do
      expect { described_class.validate_publish!('') }.to raise_error(ArgumentError)
    end

    it 'rejects empty segments' do
      expect { described_class.validate_publish!('a..b') }
        .to raise_error(ArgumentError, /empty segment/)
    end

    it 'rejects `*` wildcards' do
      expect { described_class.validate_publish!('a.*') }
        .to raise_error(ArgumentError, /wildcards are not allowed/)
    end

    it 'rejects `>` wildcards' do
      expect { described_class.validate_publish!('a.>') }
        .to raise_error(ArgumentError, /wildcards are not allowed/)
    end
  end
end
