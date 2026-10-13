# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/storages'
require 'glazed/storages/memory'

RSpec.describe Glazed::Storages::Memory do
  def location(pointer) = pointer.location.unpack(Glazed::Proto::V1::MemoryLocation)

  let(:storage) { described_class.new }

  it_behaves_like 'a conditional storage'

  it 'returns content written earlier in the process' do
    result = storage.write(key: 'core/rt1', content: "hostname rt1\n", message: 'x')
    expect(result).to be_changed
    expect(location(result.pointer).to_h).to eq(key: 'core/rt1', sha256: Digest::SHA256.hexdigest("hostname rt1\n"))
    expect(storage.read(result.pointer)).to eq("hostname rt1\n")
  end

  it 'reports a rewrite of the same content unchanged' do
    storage.write(key: 'rt1', content: "x\n", message: 'x')
    results = storage.write_all([['rt1', "x\n"], ['rt2', "y\n"]], message: ->(_) { 'unused' })
    expect(results.map(&:changed?)).to eq([false, true])
  end

  it 'keeps earlier content readable after the key is overwritten' do
    first = storage.write(key: 'rt1', content: "v1\n", message: 'x').pointer
    storage.write(key: 'rt1', content: "v2\n", message: 'x')
    expect(storage.read(first)).to eq("v1\n")
  end

  it 'refuses a pointer to content another process wrote' do
    pointer = described_class.new.write(key: 'rt1', content: "x\n", message: 'x').pointer
    expect { storage.read(pointer) }.to raise_error(described_class::MissingContent, /only works within one glazed run/)
  end

  it 'is built from a config' do
    expect(Glazed::Storages.build(Glazed::Proto::V1::StorageConfig.new(memory: {}))).to be_a(described_class)
  end
end
