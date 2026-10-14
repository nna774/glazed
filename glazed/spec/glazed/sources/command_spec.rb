# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'glazed/sources'
require 'glazed/sources/command'

RSpec.describe Glazed::Sources::Command do
  def nodes(**settings) = Glazed::Sources.nodes([Glazed::Proto::V1::InventorySource.new(command: settings)])

  it 'reads the inventory file the command prints' do
    document = JSON.generate(defaults: {dialect: 'ios'}, nodes: [{name: 'rt1'}, {name: 'sw1', dialect: 'junos'}])
    expect(nodes(run: "printf '%s' '#{document}'").map { [it.name, it.dialect] }).to eq([%w[rt1 ios], %w[sw1 junos]])
  end

  it 'reads the inventory file a program prints when run with its arguments' do
    expect(nodes(exec: ['printf', '%s', '{"nodes": [{"name": "rt1", "dialect": "ios"}]}']).map(&:name)).to eq(%w[rt1])
  end

  it 'fails when the command fails' do
    expect { nodes(run: 'echo broken >&2; exit 3') }.to raise_error(Glazed::ShellCommand::Failed, /exited with 3: broken/)
  end

  it 'rejects output that is not an inventory file' do
    expect { nodes(run: 'echo not json') }.to raise_error(Glazed::Sources::Base::InvalidInventory, /command echo not json/)
  end

  it 'checks the output against the schema' do
    expect { nodes(run: %(echo '{"nodes": [{"name": "rt1"}]}')) }.to raise_error(Glazed::InvalidMessage, /every node needs a dialect/)
  end

  it 'times out' do
    expect { described_class.new(run: 'sleep 5', timeout: 0.1).nodes }.to raise_error(Glazed::TimeoutError)
  end
end
