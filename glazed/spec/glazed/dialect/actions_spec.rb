# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialect/actions'

RSpec.describe Glazed::Dialect::Actions do
  let(:append) { Glazed::Dialect::Actions::Append }
  let(:replace) { Glazed::Dialect::Actions::Replace }
  let(:multi) { Glazed::Dialect::Actions::Multi }

  describe '.apply' do
    it 'appends' do
      expect(described_class.apply('a', append.new(content: 'b'))).to eq('ab')
    end

    it 'replaces' do
      expect(described_class.apply('a', replace.new(content: 'b'))).to eq('b')
    end

    it 'treats a String as Append' do
      expect(described_class.apply('a', 'b')).to eq('ab')
    end

    it 'ignores nil' do
      expect(described_class.apply('a', nil)).to eq('a')
    end

    it 'applies Multi in order' do
      expect(described_class.apply('a', multi.new(append.new(content: 'b'), replace.new(content: 'c'), 'd'))).to eq('cd')
    end

    it 'leaves the given buffer untouched' do
      buffer = +'a'
      described_class.apply(buffer, 'b')
      expect(buffer).to eq('a')
    end
  end

  describe Glazed::Dialect::Actions::Multi do
    it 'flattens nested Multi and drops nil' do
      expect(multi.new(multi.new('a', nil), 'b').actions).to eq([append.new(content: 'a'), append.new(content: 'b')])
    end
  end

  it 'compares actions by class and content' do
    expect(append.new(content: 'a')).to eq(append.new(content: 'a'))
    expect(append.new(content: 'a')).not_to eq(replace.new(content: 'a'))
  end
end
