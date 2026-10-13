# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'tmpdir'
require 'glazed/proto_json'
require 'glazed/steps/fetch'
require 'glazed/storages/git'

RSpec.describe Glazed::Steps::Fetch do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:context) { Glazed::StepContext.new(storages: {'vault' => Glazed::Storages::Git.new(path: @dir)}) }
  let(:step) { described_class.from_proto('fetch', Glazed::Proto::V1::FetchStep.new(output: 'raw', storage: 'vault', timeout_seconds: 1), context:) }
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

  it 'adds the stored configuration as an artifact' do
    state = step.call(Glazed::Proto::V1::NodeState.new(node:))
    artifact = state.artifacts['raw']
    expect(artifact.storage).to eq('vault')
    expect(artifact.pointer.git.path).to eq('core/rt1')
    expect(context.read(artifact)).to eq("hostname rt1\n")
  end

  it 'marks the artifact unchanged when the device returns the same configuration' do
    expect(step.call(Glazed::Proto::V1::NodeState.new(node:)).artifacts['raw'].changed).to be(true)
    expect(step.call(Glazed::Proto::V1::NodeState.new(node:)).artifacts['raw'].changed).to be(false)
  end

  it 'leaves the given state untouched and round-trips through ProtoJSON' do
    input = Glazed::Proto::V1::NodeState.new(node:)
    state = step.call(input)
    expect(input.artifacts.to_h).to be_empty
    expect(Glazed::ProtoJson.load(Glazed::Proto::V1::NodeState, Glazed::ProtoJson.dump(state))).to eq(state)
  end

  it 'declares its output' do
    expect([step.inputs, step.outputs]).to eq([[], ['raw']])
  end

  it 'rejects a definition without a storage' do
    expect { described_class.from_proto('fetch', Glazed::Proto::V1::FetchStep.new(output: 'raw'), context:) }
      .to raise_error(Glazed::Steps::InvalidStep)
  end

  it 'rejects an unknown storage' do
    expect { described_class.from_proto('fetch', Glazed::Proto::V1::FetchStep.new(output: 'raw', storage: 'nope'), context:) }
      .to raise_error(Glazed::StepContext::UnknownStorage, /nope/)
  end
end
