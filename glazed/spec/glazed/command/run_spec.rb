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
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  after { device.close }

  def path(*parts) = File.join(@dir, *parts)

  def write_json(name, document) = path(name).tap { File.write(it, JSON.generate(document)) }

  def git_show(repo, spec) = Open3.capture2('git', '-C', path(repo), 'show', spec).first

  def run_command(*options)
    write_json('inventory.json', defaults: {group: 'core', dialect: 'ios', transport: 'telnet', username: 'admin', password: {env: 'GLAZED_TEST_PASSWORD'}}, nodes:)
    config = write_json('glazed.json',
      inventory: [path('inventory.json')],
      raw: {git: {path: path('raw')}},
      redacted: {git: {path: path('redacted')}},
      redaction: {mode: 'MODE_HMAC', hmac_key: {value: 'k'}},
      timeout_seconds: 2)
    stub_const('ENV', ENV.to_h.merge('GLAZED_TEST_PASSWORD' => 'pw'))
    Glazed::Command.start(['run', '-c', config, *options], out:, err:)
  end

  it 'stores raw and redacted configuration and reports the failed node' do
    expect(run_command).to eq(1)
    expect(git_show('raw', 'HEAD:core/sw1')).to eq(simulation.expected('collected'))

    redacted = git_show('redacted', 'HEAD:core/sw1')
    expect(redacted).to include('enable secret 9 <secret hmac:')
    simulation.secrets.each { expect(redacted).not_to include(it) }
    expect(Open3.capture2('git', '-C', path('redacted'), 'log', '--format=%s').first).to eq("update sw1\n")

    logs = err.string.lines.map { JSON.parse(it) }
    expect(logs).to contain_exactly(
      {'level' => 'info', 'node' => 'sw1', 'message' => 'fetched'},
      include('level' => 'error', 'node' => 'sw2'),
    )
    expect(out.string).to eq("fetched 1 of 2 nodes, 1 failed\n")
  end

  it 'exits 0 when every node succeeds' do
    nodes.pop
    expect(run_command).to eq(0)
  end

  it 'fetches only the named nodes' do
    expect(run_command('--only', 'sw1')).to eq(0)
    expect(out.string).to eq("fetched 1 of 1 nodes, 0 failed\n")
  end

  it 'exits 2 without a config' do
    expect(Glazed::Command.start(%w[run], out:, err:)).to eq(2)
    expect(err.string).to include('--config')
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
    expect(described_class.start(['nope'], err:)).to eq(2)
    expect(err.string).to include('Usage: glazed')
  end
end
