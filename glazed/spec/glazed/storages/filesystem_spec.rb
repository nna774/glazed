# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'tmpdir'
require 'glazed/storages'
require 'glazed/storages/filesystem'

RSpec.describe Glazed::Storages::Filesystem do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:path) { File.join(@dir, 'latest') }
  let(:storage) { described_class.new(path:) }

  it 'writes each key as a file under the directory' do
    result = storage.write(key: 'core/rt1', content: "hostname rt1\n", message: 'x')
    expect(result).to be_changed
    expect(File.read(File.join(path, 'core/rt1'))).to eq("hostname rt1\n")
    expect(result.pointer.filesystem.to_h).to eq(path: 'core/rt1', sha256: Digest::SHA256.hexdigest("hostname rt1\n"))
    expect(Dir.children(File.join(path, 'core'))).to eq(['rt1'])
  end

  it 'leaves an identical file untouched' do
    storage.write(key: 'rt1', content: "x\n", message: 'x')
    File.utime(Time.at(0), Time.at(0), File.join(path, 'rt1'))
    expect(storage.write(key: 'rt1', content: "x\n", message: 'x')).not_to be_changed
    expect(File.mtime(File.join(path, 'rt1'))).to eq(Time.at(0))
  end

  it 'reads the content a pointer names' do
    pointer = storage.write(key: 'rt1', content: "x\n", message: 'x').pointer
    expect(storage.read(pointer)).to eq("x\n")
  end

  it 'refuses a pointer to content that has since been replaced' do
    pointer = storage.write(key: 'rt1', content: "v1\n", message: 'x').pointer
    storage.write(key: 'rt1', content: "v2\n", message: 'x')
    expect { storage.read(pointer) }.to raise_error(described_class::StaleContent, /rt1/)
  end

  it 'reports per-file changes in a batch' do
    storage.write(key: 'rt1', content: "a\n", message: 'x')
    results = storage.write_all([['rt1', "a\n"], ['rt2', "b\n"]], message: ->(_) { 'unused' })
    expect(results.map(&:changed?)).to eq([false, true])
  end

  it 'rejects keys that could escape the directory' do
    expect { storage.write(key: '../x', content: '', message: 'x') }.to raise_error(Glazed::Storages::Base::InvalidKey)
  end

  it 'is built from a config' do
    storage = Glazed::Storages.build(Glazed::Proto::V1::StorageConfig.new(filesystem: {path: '/srv/configs'}))
    expect(storage).to be_a(described_class).and(have_attributes(path: '/srv/configs'))
  end
end
