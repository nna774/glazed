# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'open3'
require 'stringio'
require 'tmpdir'
require 'glazed/command'

RSpec.describe 'glazed run' do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:simulation) { Simulation.load('ios/C9200L-24P-4G_17.09.04a') }
  let(:device) { TelnetDevice.new(simulation, username: 'admin', password: 'pw') }
  let(:closed_port) { TCPServer.new('127.0.0.1', 0).then { |server| server.addr[1].tap { server.close } } }
  let(:nodes) do
    [
      {name: 'sw1', host: '127.0.0.1', port: device.port},
      {name: 'sw2', host: '127.0.0.1', port: closed_port},
    ]
  end
  let(:workflows) do
    {
      backup: {
        steps: [
          {name: 'fetch', fetch: {output: 'raw', storage: 'vault', timeout_seconds: 2}},
          {name: 'redact', redact: {input: 'raw', output: 'redacted', storage: 'staging',
                                      redaction: {mode: 'MODE_HMAC', hmac_key: {value: 'aw=='}}}},
          {name: 'publish', publish: {input: 'redacted', storage: 'team'}},
        ],
      },
    }
  end
  let(:vault) { {git: {path: path('vault')}} }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  after { device.close }

  def path(*parts) = File.join(@dir, *parts)

  def write_json(name, document) = path(name).tap { File.write(it, JSON.generate(document)) }

  def git_show(repo, spec) = Open3.capture2('git', '-C', path(repo), 'show', spec).first

  def run_command(*options)
    write_json('inventory.json', defaults: {group: 'core', dialect: 'ios', transport: 'telnet', username: 'admin', password: {env: 'GLAZED_TEST_PASSWORD'}}, nodes:)
    config = write_json('glazed.json',
      inventory: [{json_files: {paths: [path('inventory.json')]}}],
      storages: {
        vault:,
        staging: {git: {path: path('staging')}},
        team: {git: {path: path('team')}},
      },
      workflows:)
    stub_const('ENV', ENV.to_h.merge('GLAZED_TEST_PASSWORD' => 'pw'))
    Glazed::Command.start(['run', '-c', config, *options], out:, err:)
  end

  it 'runs every step and reports the failed node' do
    expect(run_command).to eq(1)
    expect(git_show('vault', 'HEAD:core/sw1')).to eq(simulation.expected('collected'))

    redacted = git_show('team', 'HEAD:core/sw1')
    expect(redacted).to include('enable secret 9 [~REDACTED:dgst=')
    simulation.secrets.each { expect(redacted).not_to include(it) }
    expect(Open3.capture2('git', '-C', path('team'), 'log', '--format=%s').first).to eq("publish: update sw1\n")

    logs, progress = err.string.lines.map { JSON.parse(it) }.partition { it['message'] == 'done' || it['level'] == 'error' }
    expect(progress).to include({'level' => 'info', 'step' => 'fetch', 'node' => 'sw1', 'message' => 'connecting to 127.0.0.1 over telnet'})
    expect(logs).to contain_exactly(
      {'level' => 'info', 'step' => 'fetch', 'node' => 'sw1', 'changed' => true, 'message' => 'done'},
      {'level' => 'info', 'step' => 'redact', 'node' => 'sw1', 'changed' => true, 'message' => 'done'},
      include('level' => 'error', 'step' => 'fetch', 'node' => 'sw2'),
      {'level' => 'info', 'step' => 'publish', 'nodes' => 1, 'message' => 'done'},
    )
    expect(out.string).to eq("completed 1 of 2 nodes, 1 changed, 1 failed\n")
  end

  it 'writes nothing new when no device changed' do
    nodes.pop
    run_command
    commits = %w[vault staging team].to_h { [it, git_show(it, 'HEAD')] }
    out.truncate(0)
    out.rewind
    err.truncate(0)
    err.rewind

    expect(run_command).to eq(0)
    expect(out.string).to eq("completed 1 of 1 nodes, 0 changed, 0 failed\n")
    expect(%w[vault staging team].to_h { [it, git_show(it, 'HEAD')] }).to eq(commits)
    expect(err.string.lines.map { JSON.parse(it) }.select { it['node'] && it['message'] == 'done' }).to all(include('changed' => false))
  end

  it 'publishes the redacted copy without persisting the raw one in memory storage' do
    nodes.pop
    vault.replace(memory: {})
    expect(run_command).to eq(0)
    expect(git_show('team', 'HEAD:core/sw1')).to include('enable secret 9 [~REDACTED:dgst=')
    expect(File.exist?(path('vault'))).to be(false)
    expect(Dir.children(@dir)).to contain_exactly('inventory.json', 'glazed.json', 'staging', 'team')
  end

  it 'exits 0 when every node succeeds' do
    nodes.pop
    expect(run_command).to eq(0)
  end

  it 'runs only for the named nodes' do
    expect(run_command('--only', 'sw1')).to eq(0)
    expect(out.string).to eq("completed 1 of 1 nodes, 1 changed, 0 failed\n")
  end

  it 'runs nodes in parallel with --jobs' do
    expect(run_command('-j', '8')).to eq(1)
    expect(out.string).to eq("completed 1 of 2 nodes, 1 changed, 1 failed\n")
  end

  it 'refuses --jobs that is not a positive integer' do
    expect { run_command('--jobs', 'many') }.to raise_error(Glazed::Error, /--jobs must be a positive integer, got "many"/)
    expect { run_command('--jobs', '0') }.to raise_error(Glazed::Error, /--jobs/)
  end

  it 'runs a raw-only workflow' do
    workflows[:backup][:steps].pop(2)
    nodes.pop
    expect(run_command).to eq(0)
    expect(File.exist?(path('team'))).to be(false)
  end

  it 'exits 1 without a config' do
    stub_const('ENV', ENV.to_h.except('GLAZED_CONFIG_FILE'))
    expect(Glazed::Command.start(%w[run], out:, err:)).to eq(1)
    expect(err.string).to include('--config or GLAZED_CONFIG_FILE is required')
  end

  it 'reads the config named by GLAZED_CONFIG_FILE' do
    nodes.pop
    run_command
    stub_const('ENV', ENV.to_h.merge('GLAZED_CONFIG_FILE' => path('glazed.json')))
    out.truncate(0)
    out.rewind
    expect(Glazed::Command.start(%w[run], out:, err:)).to eq(0)
    expect(out.string).to eq("completed 1 of 1 nodes, 0 changed, 0 failed\n")
  end
end

RSpec.describe 'glazed run with several workflows' do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def start(*args)
    File.write(File.join(@dir, 'inventory.json'), JSON.generate(nodes: []))
    config = File.join(@dir, 'glazed.json')
    step = {name: 'fetch', fetch: {output: 'raw', storage: 'vault'}}
    File.write(config, JSON.generate(
      inventory: [{json_files: {paths: [File.join(@dir, 'inventory.json')]}}],
      storages: {vault: {git: {path: File.join(@dir, 'vault')}}},
      workflows: {hourly: {steps: [step]}, daily: {steps: [step]}},
    ))
    Glazed::Command.start(['run', '-c', config, *args], out: StringIO.new, err: StringIO.new)
  end

  it 'runs the named workflow' do
    expect(start('-w', 'daily')).to eq(0)
  end

  it 'requires choosing one' do
    expect { start }.to raise_error(Glazed::Error, /--workflow: daily, hourly/)
  end
end

RSpec.describe Glazed::Command do
  it 'prints the version' do
    out = StringIO.new
    expect(described_class.start(['version'], out:)).to eq(0)
    expect(out.string).to eq("#{Glazed::VERSION}\n")
  end

  it 'prints usage for an unknown command' do
    err = StringIO.new
    expect(described_class.start(['nope'], err:)).to eq(1)
    expect(err.string).to include('# Run a workflow', '# Print the version')
  end
end

RSpec.describe 'glazed run with plugins' do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:plugin_file) { File.expand_path('../../fixtures/plugins/marker_step.rb', __dir__) }

  def start(requires:, type:)
    config = File.join(@dir, 'glazed.json')
    File.write(config, JSON.generate(
      requires:,
      inventory: [{inline: {nodes: []}}],
      workflows: {hooks: {steps: [{name: 'mark', plugin: {'@type' => "type.googleapis.com/#{type}", 'text' => 'hello'}}]}},
    ))
    Glazed::Command.start(['run', '-c', config], out: StringIO.new, err: StringIO.new)
  end

  it 'requires plugins before decoding a config that uses them, all in one file' do
    expect(start(requires: [plugin_file], type: 'glazed_test.v1.Marker')).to eq(0)
    expect(GlazedTestPlugin.calls).to include(['hello', 0])
  end

  it 'hints at requires when a plugin type is unknown' do
    expect { start(requires: [], type: 'glazed_test.v1.Missing') }
      .to raise_error(Glazed::Error, /Type was not found; list the gem providing that plugin type in requires/)
  end

  it 'rejects requires that is not a list of strings' do
    expect { start(requires: 'x', type: 'glazed_test.v1.Missing') }.to raise_error(Glazed::Error, /requires must be a list of strings/)
  end
end
