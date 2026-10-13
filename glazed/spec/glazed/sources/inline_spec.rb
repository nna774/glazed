# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'glazed/sources'
require 'glazed/sources/inline'

RSpec.describe Glazed::Sources::Inline do
  def source(document) = Glazed::ProtoJson.load(Glazed::Proto::V1::InventorySource, JSON.generate(inline: document))

  def nodes(document) = Glazed::Sources.nodes([source(document)])

  it 'applies defaults to fields a node leaves unset' do
    document = {
      defaults: {group: 'core', dialect: 'ios', password: {env: 'PW'}},
      nodes: [{name: 'rt1'}, {name: 'sw1', dialect: 'junos', password: {value: 'x'}}],
    }
    expect(nodes(document).map { [it.name, it.group, it.dialect, it.password.source] }).to eq([
      ['rt1', 'core', 'ios', :env],
      ['sw1', 'core', 'junos', :value],
    ])
  end

  it 'merges params and secrets key by key' do
    node = nodes(defaults: {dialect: 'ios', params: {a: '1', b: '2'}}, nodes: [{name: 'rt1', params: {b: '3'}}]).first
    expect(node.params.to_h).to eq('a' => '1', 'b' => '3')
  end

  it 'replaces transport_options of defaults as a whole' do
    document = {
      defaults: {dialect: 'ios', transportOptions: {ssh: {compression: true, keys: [{path: '/a'}]}}},
      nodes: [{name: 'rt1'}, {name: 'sw1', transportOptions: {ssh: {forwardAgent: true}}}],
    }
    rt1, sw1 = nodes(document)
    expect(rt1.transport_options.ssh.keys.map(&:path)).to eq(['/a'])
    expect([sw1.transport_options.ssh.compression, sw1.transport_options.ssh.forward_agent, sw1.transport_options.ssh.keys.size]).to eq([false, true, 0])
  end

  it 'rejects an ssh key without a source' do
    expect { nodes(nodes: [{name: 'rt1', dialect: 'ios', transportOptions: {ssh: {keys: [{}]}}}]) }
      .to raise_error(Glazed::InvalidMessage)
  end

  it 'rejects a node without a dialect' do
      expect { nodes(nodes: [{name: 'rt1'}]) }
        .to raise_error(Glazed::InvalidMessage, /inline: every node needs a dialect/)
    end

  it 'combines with other sources under the uniqueness check' do
    expect { Glazed::Sources.nodes([source(nodes: [{name: 'rt1', dialect: 'ios'}])] * 2) }
      .to raise_error(Glazed::Sources::DuplicateNode, /inline inventory and inline inventory/)
  end
end
