# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'tmpdir'
require 'glazed/steps/fetch'
require 'glazed/storages/git'

RSpec.describe Glazed::Steps::Fetch do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:storage) { Glazed::Storages::Git.new(path: @dir) }
  let(:dialect) do
    Class.new(Glazed::Dialects::Base) do
      prompt(/^rt1#\s?$/)
      runbook(:get) { it.command('show running-config') }
    end
  end
  let(:node) { Glazed::Proto::V1::Node.new(name: 'rt1', group: 'core', dialect: 'test_os', transport: 'fake') }

  before do
    stub_const('Glazed::Dialects::TestOs', dialect)
    stub_const('Glazed::Transports::Fake', FakeTransport.device(greeting: 'rt1#', responses: {'show running-config' => "hostname rt1\nrt1#"}))
  end

  it 'stores the raw configuration under the node key' do
    result = described_class.new(storage:, timeout: 1).call(Glazed::Proto::V1::FetchRequest.new(node:))
    expect(result.node).to eq(node)
    expect(result.raw.git.path).to eq('core/rt1')
    expect(storage.read(result.raw)).to eq("hostname rt1\n")
  end

  it 'round-trips through ProtoJSON' do
    result = described_class.new(storage:, timeout: 1).call(Glazed::Proto::V1::FetchRequest.new(node:))
    expect(Glazed::ProtoJson.load(Glazed::Proto::V1::FetchResult, Glazed::ProtoJson.dump(result))).to eq(result)
  end

  it 'rejects a request without a node' do
    expect { described_class.new(storage:).call(Glazed::Proto::V1::FetchRequest.new) }.to raise_error(ArgumentError)
  end
end
