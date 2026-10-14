# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'stringio'
require 'tmpdir'
require 'glazed/command'

RSpec.describe 'glazed orchestrate and glazed signal' do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:simulation) { Simulation.load('ios/C9200L-24P-4G_17.09.04a') }
  let(:device) { TelnetDevice.new(simulation, username: 'admin', password: 'pw') }
  let(:orchestrator) { {state: {sqlite: {path: path('state.sqlite3')}}, workflows: {backup: {debounce: {delay_seconds: 120}}, audit: {}}} }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  after { device.close }

  def path(*parts) = File.join(@dir, *parts)

  def config
    File.write(path('inventory.json'), JSON.generate(
      defaults: {group: 'core', dialect: 'ios', transport: 'telnet', username: 'admin', password: {value: 'pw'}},
      nodes: [{name: 'sw1', host: '127.0.0.1', port: device.port}],
    ))
    path('glazed.json').tap do |file|
      File.write(file, JSON.generate(
        inventory: [{json_files: {paths: [path('inventory.json')]}}],
        storages: {raw: {memory: {}}, latest: {filesystem: {path: path('latest')}}},
        workflows: {
          backup: {steps: [
            {name: 'fetch', fetch: {output: 'raw', storage: 'raw', timeout_seconds: 2}},
            {name: 'publish', publish: {input: 'raw', storage: 'latest'}},
          ]},
          audit: {steps: [{name: 'count', batch_command: {run: 'cat > /dev/null'}}]},
        },
        orchestrator:,
      ))
    end
  end

  def events = err.string.lines.map { JSON.parse(it) }

  # Runs the orchestrator on the main thread, sending TERM once a batch finished.
  def run_orchestrator
    file = config
    killer = Thread.new do
      deadline = Time.now + 10
      sleep 0.05 until err.string.include?('batch finished') || Time.now > deadline
      Process.kill('TERM', Process.pid)
    end
    Glazed::Command.start(['orchestrate', '-c', file], out:, err:)
  ensure
    killer&.join
  end

  it 'runs new nodes, then stops after the batch on TERM' do
    expect(run_orchestrator).to eq(0)
    expect(File.read(path('latest', 'core', 'sw1'))).to eq(simulation.expected('collected'))
    expect(events.map { it['message'] }).to include('orchestrator started', 'inventory changed', 'batch started', 'batch finished', 'orchestrator stopped')
    expect(events.select { it['message'] == 'batch finished' }.map { it['workflow'] }).to contain_exactly('audit', 'backup')
    expect(Signal.trap('TERM', 'DEFAULT')).to eq('DEFAULT')
  end

  it 'records a signal for every orchestrated workflow with its debounce delay' do
    run_orchestrator
    before = Time.now
    expect(Glazed::Command.start(['signal', '-c', config, '--source', 'syslog', 'sw1'], out:, err:)).to eq(0)
    lines = out.string.lines
    expect(lines.map { it.split.first(2) }).to eq([%w[sw1 audit], %w[sw1 backup]])
    expect(lines).to all(match(/ due at \S+Z\n\z/))
    expect(Time.iso8601(lines.last.split.last)).to be_within(2).of(before + 120)
    expect(Time.iso8601(lines.first.split.last)).to be_within(2).of(before + 60)
  end

  it 'records an immediate signal for the chosen workflow' do
    expect(Glazed::Command.start(['signal', '-c', config, '-w', 'backup', '--now', 'sw1'], out:, err:)).to eq(0)
    expect(out.string.lines.size).to eq(1)
    expect(Time.iso8601(out.string.split.last)).to be_within(2).of(Time.now)
  end

  it 'signals with the config named by GLAZED_CONFIG_FILE' do
    stub_const('ENV', ENV.to_h.merge('GLAZED_CONFIG_FILE' => config))
    expect(Glazed::Command.start(['signal', '-w', 'backup', 'sw1'], out:, err:)).to eq(0)
    expect(out.string).to start_with('sw1 backup due at ')
  end

  it 'signals every node with --all' do
    expect(Glazed::Command.start(['signal', '-c', config, '-w', 'backup', '--all', '--source', 'daily'], out:, err:)).to eq(0)
    expect(out.string.lines.map { it.split.first(2) }).to eq([%w[sw1 backup]])
  end

  it 'refuses node names with --all, and neither' do
    expect(Glazed::Command.start(['signal', '-c', config, '--all', 'sw1'], out:, err:)).to eq(1)
    expect(Glazed::Command.start(['signal', '-c', config], out:, err:)).to eq(1)
    expect(err.string).to include('name nodes, or give --all')
  end

  it 'refuses to signal a workflow not orchestrated' do
    expect { Glazed::Command.start(['signal', '-c', config, '-w', 'nope', 'sw1'], out:, err:) }.to raise_error(Glazed::Error, /not orchestrated workflows: nope/)
  end

  it 'refuses to signal an unknown node' do
    expect { Glazed::Command.start(['signal', '-c', config, 'nope'], out:, err:) }.to raise_error(Glazed::Error, /unknown nodes: nope/)
  end

  it 'requires orchestrator settings' do
    orchestrator.clear
    file = config
    File.write(file, JSON.generate(JSON.parse(File.read(file)).except('orchestrator')))
    expect { Glazed::Command.start(['orchestrate', '-c', file], out:, err:) }.to raise_error(Glazed::Error, /orchestrator is not configured/)
  end
end
