# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'tmpdir'
require 'glazed/aws/lambda'

RSpec.describe Glazed::Aws::Lambda do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    ensure
      described_class.reset
    end
  end

  let(:events) { [] }
  let(:config) do
    File.join(@dir, 'glazed.json').tap do |file|
      File.write(file, JSON.generate(
        inventory: [{inline: {defaults: {dialect: 'ios'}, nodes: [{name: 'rt1'}, {name: 'sw1'}]}}],
        storages: {'raw' => {filesystem: {path: File.join(@dir, 'raw')}}},
        workflows: {'backup' => {steps: [
          {name: 'fetch', shell: {run: 'echo "config of $GLAZED_NODE_NAME"', output: 'raw', storage: 'raw'}},
          {name: 'publish', batch_shell: {run: "cat >> #{File.join(@dir, 'published')}"}},
        ]}},
        orchestrator: {
          state: {sqlite: {path: File.join(@dir, 'state.sqlite3')}},
          workflows: {'backup' => {debounce: {delay_seconds: 60}}},
        },
      ))
    end
  end

  def invoke(event) = described_class.handle(event, environment: {'GLAZED_CONFIG_FILE' => config}, listener: ->(event) { events << event })

  it 'runs a cycle of check, prepare, steps and complete' do
    signals = {'signals' => [{'all_nodes' => true, 'source' => 'daily', 'immediate' => true}]}
    armed = invoke('task' => {'check' => {'token' => 'E1'}}, 'execution_input' => signals)
    expect(Time.iso8601(armed.fetch('wait_until'))).to be_within(5).of(Time.now)

    batch = invoke('task' => {'prepare' => {}}).dig('batches', 'backup')
    expect(batch['nodes'].map { it.dig('state', 'node', 'name') }).to eq(%w[rt1 sw1])

    nodes = batch['nodes'].map { invoke('task' => {'node_step' => {'workflow' => 'backup', 'step' => 'fetch', 'outcome' => it}}) }
    expect(nodes.map { it.dig('state', 'artifacts', 'raw', 'changed') }).to eq([true, true])
    batch = invoke('task' => {'batch_step' => {'step' => 'publish', 'batch' => batch.merge('nodes' => nodes)}})
    invoke('task' => {'complete' => {'batch' => batch}})

    expect(File.read(File.join(@dir, 'raw', 'sw1'))).to eq("config of sw1\n")
    expect(JSON.parse(File.read(File.join(@dir, 'published')))['nodes'].size).to eq(2)
    expect(events).to include(include(message: 'batch finished', nodes: 2, failed: 0))

    armed = invoke('task' => {'check' => {'token' => 'E2'}}, 'execution_input' => {'detail-type' => 'x', 'source' => 'syslog', 'detail' => {'node' => 'sw1'}})
    expect(armed).to eq({})
  end

  it 'loads the config once' do
    invoke('task' => {'prepare' => {}})
    File.write(config, '{')
    expect { invoke('task' => {'prepare' => {}}) }.not_to raise_error
  end

  it 'requires the config file to be named' do
    expect { described_class.handle({'task' => {'prepare' => {}}}, environment: {}) }.to raise_error(Glazed::Error, /GLAZED_CONFIG_FILE/)
  end
end
