# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/storages'

RSpec.describe Glazed::Storages do
  describe '.build' do
    it 'builds the selected backend' do
      config = Glazed::Proto::V1::StorageConfig.new(git: {path: '/x', branch: 'b'})
      storage = described_class.build(config)
      expect(storage).to be_a(Glazed::Storages::Git)
      expect(storage.branch).to eq('b')
    end

    it 'raises MissingBackend for an empty config' do
      expect { described_class.build(Glazed::Proto::V1::StorageConfig.new) }.to raise_error(described_class::MissingBackend)
    end
  end

  describe '.key_for' do
    it 'joins group and name' do
      expect(described_class.key_for(Glazed::Proto::V1::Node.new(name: 'rt1', group: 'core'))).to eq('core/rt1')
      expect(described_class.key_for(Glazed::Proto::V1::Node.new(name: 'rt1'))).to eq('rt1')
    end
  end
end
