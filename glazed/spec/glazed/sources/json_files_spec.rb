# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'tmpdir'
require 'glazed/sources/json_files'

RSpec.describe Glazed::Sources::JsonFiles do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def write(name, document)
    File.join(@dir, name).tap { File.write(it, JSON.generate(document)) }
  end

  def nodes(*patterns) = described_class.new(paths: patterns.map { File.join(@dir, it) }).nodes

  it 'reads nodes across files matched by a glob' do
    write('a.json', nodes: [{name: 'rt1', dialect: 'ios'}])
    write('b.json', nodes: [{name: 'sw1', dialect: 'junos'}])
    expect(nodes('*.json').map(&:name)).to eq(%w[rt1 sw1])
  end

  it 'applies defaults to fields a node leaves unset' do
    write('a.json', defaults: {group: 'core', dialect: 'ios', username: 'admin'},
      nodes: [{name: 'rt1'}, {name: 'rt2', dialect: 'nec_ix'}])
    expect(nodes('a.json').map { [it.name, it.group, it.dialect, it.username] })
      .to eq([%w[rt1 core ios admin], %w[rt2 core nec_ix admin]])
  end

  it 'merges params and secrets key by key' do
    write('a.json', defaults: {dialect: 'ios', params: {a: '1', b: '2'}, secrets: {enable: {env: 'E'}}},
      nodes: [{name: 'rt1', params: {b: '3'}, secrets: {other: {value: 'x'}}}])
    node = nodes('a.json').first
    expect(node.params.to_h).to eq('a' => '1', 'b' => '3')
    expect(node.secrets.to_h.keys).to contain_exactly('enable', 'other')
  end

  it 'replaces a default password instead of merging its sources' do
    write('a.json', defaults: {dialect: 'ios', password: {env: 'PW'}},
      nodes: [{name: 'rt1', password: {value: 'x'}}])
    expect(nodes('a.json').first.password.source).to eq(:value)
  end

  it 'raises DuplicateNode naming both files' do
    a = write('a.json', nodes: [{name: 'rt1', dialect: 'ios'}])
    b = write('b.json', nodes: [{name: 'rt1', dialect: 'ios'}])
    expect { nodes('*.json') }.to raise_error(Glazed::Sources::DuplicateNode, /#{a}.*#{b}/)
  end

  it 'raises InvalidFile for unknown fields' do
    write('a.json', nodes: [{name: 'rt1', dialect: 'ios', hostname: 'typo'}])
    expect { nodes('a.json') }.to raise_error(described_class::InvalidFile, /a\.json/)
  end

  it 'rejects a node without a dialect, naming the file' do
    write('a.json', nodes: [{name: 'rt1'}])
    expect { nodes('a.json') }.to raise_error(Glazed::InvalidMessage, %r{/a\.json: every node needs a dialect})
  end

  it 'rejects a node without a name' do
    write('a.json', nodes: [{dialect: 'ios'}])
    expect { nodes('a.json') }.to raise_error(Glazed::InvalidMessage, /every node needs a name/)
  end

  it 'raises for a missing literal path' do
    expect { nodes('missing.json') }.to raise_error(Errno::ENOENT)
  end

  it 'returns nothing for a glob without matches' do
    expect(nodes('*.json')).to eq([])
  end
end
