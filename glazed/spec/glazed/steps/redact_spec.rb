# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'tmpdir'
require 'glazed/steps/redact'
require 'glazed/storages/git'

RSpec.describe Glazed::Steps::Redact do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:raw) { Glazed::Storages::Git.new(path: File.join(@dir, 'raw')) }
  let(:context) { Glazed::StepContext.new(storages: {'vault' => raw, 'staging' => Glazed::Storages::Git.new(path: File.join(@dir, 'staging'))}) }
  let(:settings) { Glazed::Proto::V1::RedactStep.new(input: 'raw', output: 'redacted', storage: 'staging') }
  let(:step) { described_class.from_proto('redact', settings, context:) }
  let(:node) { Glazed::Proto::V1::Node.new(name: 'rt1', dialect: 'test_os') }

  before do
    stub_const('Glazed::Dialects::TestOs', Class.new(Glazed::Dialects::Base) { sensitive_pattern(/^password (\S+)/) { it[1] } })
  end

  def state_with_raw
    pointer = raw.write(key: 'rt1', content: "password hunter2\n", message: 'raw').pointer
    Glazed::Proto::V1::NodeState.new(node:, artifacts: {'raw' => {storage: 'vault', pointer:}})
  end

  it 'stores the redacted artifact next to the input' do
    state = step.call(state_with_raw)
    expect(state.artifacts.keys).to contain_exactly('raw', 'redacted')
    expect(context.read(state.artifacts['redacted'])).to eq("password [~REDACTED~]\n")
  end

  it 'uses the configured redaction' do
    settings.redaction = Glazed::Proto::V1::Redaction.new(mode: :MODE_HMAC, hmac_key: {value: 'aw=='})
    expect(context.read(step.call(state_with_raw).artifacts['redacted'])).to match(/\[~REDACTED:dgst=[\w-]{11}~\]/)
  end

  it 'applies the redaction shared through the context' do
    shared = Glazed::Proto::V1::Redaction.new(secrets: [{regexp: 'vault'}])
    shared_context = Glazed::StepContext.new(storages: {'vault' => raw, 'staging' => Glazed::Storages::Git.new(path: File.join(@dir, 'staging'))}, redaction: shared)
    shared_step = described_class.from_proto('redact', settings, context: shared_context)
    pointer = raw.write(key: 'rt1', content: "password hunter2\nnote vault\n", message: 'raw').pointer
    state = Glazed::Proto::V1::NodeState.new(node:, artifacts: {'raw' => {storage: 'vault', pointer:}})
    expect(shared_context.read(shared_step.call(state).artifacts['redacted'])).to eq("password [~REDACTED~]\nnote [~REDACTED~]\n")
  end

  it 'raises MissingArtifact without its input' do
    expect { step.call(Glazed::Proto::V1::NodeState.new(node:)) }.to raise_error(Glazed::Steps::Base::MissingArtifact, /raw/)
  end

  it 'declares its input and output' do
    expect([step.inputs, step.outputs]).to eq([['raw'], ['redacted']])
  end
end
