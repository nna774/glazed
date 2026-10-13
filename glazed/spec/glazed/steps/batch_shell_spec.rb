# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'tmpdir'
require 'glazed/steps/batch_shell'

RSpec.describe Glazed::Steps::BatchShell do
  let(:context) { Glazed::StepContext.new(storages: {}) }
  let(:batch) do
    Glazed::Proto::V1::BatchState.new(nodes: [
      {node: {name: 'rt1'}, artifacts: {'raw' => {storage: 'files', changed: true}}},
      {node: {name: 'rt2'}, artifacts: {'raw' => {storage: 'files', changed: false}}},
    ])
  end

  def step(**settings) = described_class.from_proto('notify', Glazed::Proto::V1::BatchShellStep.new(**settings), context:)

  it 'passes the batch state as ProtoJSON on stdin and returns it unchanged' do
    Dir.mktmpdir do |dir|
      received = File.join(dir, 'stdin')
      expect(step(run: "printf '%s\\n' \"$GLAZED_STEP\" > #{received}.step; cat > #{received}").call(batch)).to eq(batch)
      expect(Glazed::ProtoJson.load(Glazed::Proto::V1::BatchState, File.read(received))).to eq(batch)
      expect(File.read("#{received}.step")).to eq("notify\n")
    end
  end

  it 'fails the run when the command fails' do
    expect { step(run: 'exit 2').call(batch) }.to raise_error(Glazed::ShellCommand::Failed, /exited with 2/)
  end

  it 'requires run' do
    expect { step }.to raise_error(Glazed::Steps::InvalidStep, /needs run/)
  end
end
