# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'tmpdir'
require 'glazed/steps/command'
require 'glazed/storages/filesystem'
require 'glazed/workflow'

RSpec.describe Glazed::Steps::Command do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:files) { Glazed::Storages::Filesystem.new(path: @dir) }
  let(:context) { Glazed::StepContext.new(storages: {'files' => files}) }
  let(:node) { Glazed::Proto::V1::Node.new(name: 'rt1', group: 'core', dialect: 'ios', password: {env: 'PW'}) }

  def step(**settings) = described_class.from_proto('script', Glazed::Proto::V1::CommandStep.new(**settings), context:)

  def state_with(content)
    pointer = files.write(key: 'core/rt1', content:, message: 'x').pointer
    Glazed::Proto::V1::NodeState.new(node:, artifacts: {'raw' => {storage: 'files', pointer:}})
  end

  it 'turns the input artifact into the output artifact through the command' do
    command = step(run: "sed -e '/^ntp clock-period/d'", input: 'raw', output: 'normalized', storage: 'files')
    state = command.call(state_with("hostname rt1\nntp clock-period 1\n"))
    expect(context.read(state.artifacts['normalized'])).to eq("hostname rt1\n")
    expect(state.artifacts['normalized'].changed).to be(true)
  end

  it 'describes the step and node in the environment, leaving secrets unresolved' do
    script = 'printf "%s|%s|%s|%s|%s|%s" "$GLAZED_STEP" "$GLAZED_NODE_NAME" "$GLAZED_NODE_GROUP" ' \
             '"$GLAZED_NODE_DIALECT" "$GLAZED_NODE_HOST" "$GLAZED_NODE"'
    command = step(run: script, output: 'env', storage: 'files')
    output = context.read(command.call(Glazed::Proto::V1::NodeState.new(node:)).artifacts['env'])
    step_name, name, group, dialect, host, json = output.split('|', 6)
    expect([step_name, name, group, dialect, host]).to eq(%w[script rt1 core ios rt1])
    expect(JSON.parse(json)).to include('name' => 'rt1', 'password' => {'env' => 'PW'})
  end

  it 'leaves the state alone without an output' do
    input = state_with("x\n")
    expect(step(run: 'cat >/dev/null', input: 'raw').call(input)).to eq(input)
  end

  it 'fails the node when the command fails' do
    expect { step(run: 'exit 1').call(Glazed::Proto::V1::NodeState.new(node:)) }.to raise_error(Glazed::ShellCommand::Failed)
  end

  it 'runs a program with its arguments' do
    stdout = File.join(@dir, 'stdout')
    step(exec: ['tee', stdout], input: 'raw').call(state_with('hostname rt1'))
    expect(File.read(stdout)).to eq('hostname rt1')
  end

  it 'requires one of run and exec, and output together with storage' do
    expect { Glazed::Steps.build(Glazed::Proto::V1::Step.new(name: 'x', command: {input: 'raw'}), context:) }
      .to raise_error(Glazed::InvalidMessage, /one of run, exec must be set/)
    expect { Glazed::Steps.build(Glazed::Proto::V1::Step.new(name: 'x', command: {run: 'true', exec: ['true']}), context:) }
      .to raise_error(Glazed::InvalidMessage, /only one of run, exec can be set/)
    expect { Glazed::Steps.build(Glazed::Proto::V1::Step.new(name: 'x', command: {run: 'true', output: 'x'}), context:) }
      .to raise_error(Glazed::InvalidMessage, /output and storage go together/)
  end

  it 'takes part in workflow wiring checks' do
    workflow = Glazed::Proto::V1::Workflow.new(steps: [{name: 'script', command: {run: 'cat', input: 'raw'}}])
    expect { Glazed::Workflow.from_proto(workflow, context:) }.to raise_error(Glazed::Workflow::Invalid, /produces raw/)
  end
end
