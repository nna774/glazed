# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'stringio'
require 'tmpdir'
require 'glazed/aws/command'
require 'glazed/aws/state_machine'
require 'glazed/proto_json'

RSpec.describe Glazed::Aws::StateMachine do
  let(:arn) { 'arn:aws:lambda:ap-northeast-1:123456789012:function:glazed' }
  let(:storages) do
    {
      'raw' => {s3: {bucket: 'raw'}},
      'team' => {github: {repository: 'example/configs', branch: 'main', token: {env: 'GITHUB_TOKEN'}}},
      'state' => {s3: {bucket: 'state'}},
    }
  end
  let(:workflows) do
    {
      'backup' => {steps: [
        {name: 'fetch', fetch: {output: 'raw', storage: 'raw'}},
        {name: 'redact', redact: {input: 'raw', output: 'redacted', storage: 'team'}},
        {name: 'publish', publish: {input: 'redacted', storage: 'team'}},
        {name: 'notify', command: {run: 'true'}},
      ]},
      'audit' => {steps: [{name: 'check', batch_command: {run: 'true'}}]},
    }
  end
  let(:document) do
    {
      storages:, workflows:, jobs: 8,
      orchestrator: {state: {sqlite: {storage: 'state', key: 'state.sqlite3'}}, workflows: workflows.keys.to_h { [it, {}] }},
    }
  end
  let(:config) { Glazed::ProtoJson.load(Glazed::Proto::V1::Config, JSON.generate(document)) }
  let(:definition) { described_class.new(config:, function_arn: arn).to_h }

  def branch(workflow) = definition.dig('States', 'Workflows', 'Branches').find { it['StartAt'] == "#{workflow}: batch" }

  it 'checks, sleeps, runs every workflow, and checks again' do
    states = definition.fetch('States')
    expect(definition).to include('QueryLanguage' => 'JSONata', 'StartAt' => 'Start')
    expect(states.transform_values { it['Next'] || it['Default'] || it['Type'] }).to eq(
      'Start' => 'Check', 'Check' => 'Armed?', 'Armed?' => 'Done', 'Sleep' => 'Prepare', 'Prepare' => 'Workflows',
      'Workflows' => 'Next cycle', 'Next cycle' => 'Check', 'Done' => 'Succeed',
    )
    expect(states.dig('Check', 'Arguments', 'Payload')).to eq(
      'task' => {'check' => {'token' => '{% $states.context.Execution.Name %}', 'cycle' => '{% $cycle %}', 'grace_seconds' => 0, 'max_cycles' => 0}},
      'execution_input' => '{% $cycle = 0 ? $states.context.Execution.Input : null %}',
    )
    expect(states.dig('Workflows', 'Branches').map { it['StartAt'] }).to eq(['audit: batch', 'backup: batch'])
  end

  it 'runs consecutive per-node steps in a Map and batch steps once' do
    states = branch('backup').fetch('States')
    expect(states.transform_values { it['Next'] || it['Default'] || it['Type'] }).to eq(
      'backup: batch' => 'backup: any due?', 'backup: any due?' => 'backup: none due', 'backup: none due' => 'Succeed',
      'backup: each node #1' => 'backup: publish', 'backup: publish' => 'backup: publish failed?',
      'backup: publish failed?' => 'backup: each node #2', 'backup: each node #2' => 'backup: complete', 'backup: complete' => 'Task',
    )
    map = states.fetch('backup: each node #1')
    expect(map['MaxConcurrency']).to eq(8)
    expect(map.dig('ItemProcessor', 'States').keys).to eq(['backup: fetch', 'backup: redact', 'backup: each node #1 done'])
    expect(map.dig('ItemProcessor', 'States', 'backup: fetch', 'Arguments')).to eq(
      'FunctionName' => arn,
      'Payload' => {'task' => {'node_step' => {'workflow' => 'backup', 'step' => 'fetch', 'outcome' => '{% $states.input %}'}}},
    )
    expect(map.dig('ItemProcessor', 'States', 'backup: fetch', 'Catch', 0, 'Next')).to eq('backup: redact')
    expect(states.dig('backup: publish', 'Catch', 0, 'Next')).to eq('backup: complete')
  end

  it 'runs a workflow of batch steps alone without a Map' do
    expect(branch('audit').fetch('States').keys).to eq(['audit: batch', 'audit: any due?', 'audit: none due', 'audit: check', 'audit: complete'])
  end

  it 'refuses memory storages' do
    storages['raw'] = {memory: {}}
    expect { definition }.to raise_error(described_class::Unsupported, /memory storages .*: raw/)
  end

  it 'warns about storages local to an instance' do
    storages['raw'] = {filesystem: {path: '/tmp/raw'}}
    storages['team'] = {git: {path: '/tmp/team'}}
    expect(described_class.new(config:, function_arn: arn).warnings).to eq([
      'storage raw is a local directory; every Lambda instance has its own',
      'storage team is a local git repository without remote; every Lambda instance has its own',
    ])
  end

  describe 'glazed-aws state-machine' do
    let(:out) { StringIO.new }
    let(:err) { StringIO.new }

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    def path = File.join(@dir, 'glazed.json').tap { File.write(it, JSON.generate(document)) }

    it 'prints the definition' do
      expect(Glazed::Aws::Command.start(['state-machine', '-c', path, '--function-arn', arn, '--max-concurrency', '2'], out:, err:)).to eq(0)
      expect(JSON.parse(out.string).dig('States', 'Workflows', 'Branches', 1, 'States', 'backup: each node #1', 'MaxConcurrency')).to eq(2)
    end

    it 'requires the function ARN' do
      expect(Glazed::Aws::Command.start(['state-machine', '-c', path], out:, err:)).to eq(1)
      expect(err.string).to include('--function-arn is required')
    end
  end
end
