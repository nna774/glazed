# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'digest'
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

  describe 'state_machine' do
    let(:arn) { 'arn:aws:lambda:ap-northeast-1:123456789012:function:glazed:7' }

    def generate(request, invoked_function_arn: arn)
      described_class.handle({'state_machine' => request}, environment: {'GLAZED_CONFIG_FILE' => config}, invoked_function_arn:, listener: ->(event) { events << event })
    end

    it 'returns the definition invoking the invoked ARN' do
      result = generate({})
      definition = JSON.parse(result.fetch('definition'))
      expect(definition).to eq(Glazed::Aws::StateMachine.new(config: Glazed::Config.load(config), function_arn: arn).to_h)
      expect(result.fetch('warnings')).to eq(['storage raw is a local directory; every Lambda instance has its own'])
    end

    it 'takes the options of glazed-aws state-machine' do
      result = generate({'function_arn' => 'arn:aws:lambda:ap-northeast-1:123456789012:function:other', 'max_concurrency' => 2, 'max_cycles' => '5'}, invoked_function_arn: nil)
      expected = Glazed::Aws::StateMachine.new(
        config: Glazed::Config.load(config), function_arn: 'arn:aws:lambda:ap-northeast-1:123456789012:function:other', max_concurrency: 2, max_cycles: 5,
      )
      expect(JSON.parse(result.fetch('definition'))).to eq(expected.to_h)
    end

    it 'requires a function ARN outside Lambda' do
      expect { generate(nil, invoked_function_arn: nil) }.to raise_error(Glazed::Error, /function_arn is required/)
    end
  end

  it 'requires the config file to be named' do
    expect { described_class.handle({'task' => {'prepare' => {}}}, environment: {}) }.to raise_error(Glazed::Error, /GLAZED_CONFIG_S3_BUCKET or GLAZED_CONFIG_FILE is required/)
  end

  describe 'config in S3' do
    let(:s3) { Aws::S3::Client.new(stub_responses: true) }
    let(:json) { File.read(config) }
    let(:digest) { [Digest::SHA256.digest(json)].pack('m0') }
    let(:environment) do
      {'GLAZED_CONFIG_S3_BUCKET' => 'conf', 'GLAZED_CONFIG_S3_KEY' => 'glazed.json', 'GLAZED_CONFIG_S3_DIGEST' => digest, 'GLAZED_CONFIG_FILE' => '/nonexistent'}
    end

    before { s3.stub_responses(:get_object, ->(_) { {body: json} }) }

    def invoke_s3(env = environment) = described_class.handle({'task' => {'prepare' => {}}}, environment: env, listener: ->(event) { events << event }, s3:)
    def gets = s3.api_requests.count { it[:operation_name] == :get_object }

    it 'reads the object once while its digest stays the same' do
      expect(invoke_s3.dig('batches', 'backup', 'workflow')).to eq('backup')
      invoke_s3
      expect(gets).to eq(1)
      expect(s3.api_requests.first[:params]).to include(bucket: 'conf', key: 'glazed.json')
    end

    it 'reads it again under another digest' do
      invoke_s3
      json << "\n"
      updated = [Digest::SHA256.digest(json)].pack('m0')
      invoke_s3(environment.merge('GLAZED_CONFIG_S3_DIGEST' => updated))
      expect(gets).to eq(2)
    end

    it 'refuses an object of another digest' do
      expected = digest
      json << "\n"
      expect { invoke_s3 }.to raise_error(Glazed::Error, %r{s3://conf/glazed.json has SHA-256 .*, not #{Regexp.escape(expected)}})
    end

    it 'requires the key and digest with the bucket' do
      expect { invoke_s3(environment.except('GLAZED_CONFIG_S3_DIGEST')) }.to raise_error(Glazed::Error, /GLAZED_CONFIG_S3_DIGEST is required/)
    end
  end
end
