# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/storages'

RSpec.describe Glazed::Finder do
  it 'requires the implementation on demand' do
    expect(described_class.find(Glazed::Storages, 'glazed/storages', 'base')).to eq(Glazed::Storages::Base)
  end

  it 'camelizes snake_case names' do
    klass = stub_const('Glazed::Storages::FooBar', Class.new)
    expect(described_class.find(Glazed::Storages, 'glazed/storages', :foo_bar)).to eq(klass)
  end

  it 'raises NotFound for an unknown name' do
    expect { described_class.find(Glazed::Storages, 'glazed/storages', 'nonexistent') }
      .to raise_error(Glazed::Finder::NotFound, /"nonexistent"/)
  end

  it 'returns nil from maybe_find for an unknown name' do
    expect(described_class.maybe_find(Glazed::Storages, 'glazed/storages', 'nonexistent')).to be_nil
  end

  it 'propagates a LoadError raised while loading the implementation' do
    error = LoadError.new('cannot load such file -- missing_dependency')
    allow(error).to receive(:path).and_return('missing_dependency')
    allow(described_class).to receive(:require).with('glazed/storages/broken').and_raise(error)
    expect { described_class.find(Glazed::Storages, 'glazed/storages', 'broken') }.to raise_error(error)
  end
end
