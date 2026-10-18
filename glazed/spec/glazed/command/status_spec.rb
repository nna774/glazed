# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'stringio'
require 'tmpdir'
require 'glazed/command'
require 'glazed/state_backends/sqlite'

RSpec.describe 'glazed status' do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:now) { Time.now }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:config) do
    File.join(@dir, 'glazed.json').tap do |file|
      File.write(file, JSON.generate(
        inventory: [{inline: {nodes: []}}],
        workflows: {backup: {steps: [{name: 'x', batch_command: {run: 'true'}}]}, audit: {steps: [{name: 'x', batch_command: {run: 'true'}}]}},
        orchestrator: {state: {sqlite: {path: File.join(@dir, 'state.sqlite3')}}, workflows: {backup: {}, audit: {}}, poll: '30s'},
      ))
    end
  end

  def ts(time) = Google::Protobuf::Timestamp.from_time(time)

  def seed(workflow, node, **fields)
    backend = Glazed::StateBackends::Sqlite.new(path: File.join(@dir, 'state.sqlite3'))
    backend.update(workflow, node) { Glazed::Proto::V1::NodeSchedule.new(workflow:, node:, **fields) }
    backend.close
  end

  def status(*args) = Glazed::Command.start(['status', '-c', config, *args], out:, err:)

  def table = out.string.lines.map { it.split(/\s{2,}/).map(&:strip) }

  context 'with healthy, running, failing and overdue nodes' do
    before do
      seed('backup', 'rt1', due_at: ts(now + 532), due_reason: 'schedule', scheduled_at: ts(now + 532),
        last_started_at: ts(now - 70), last_finished_at: ts(now - 66.6))
      seed('backup', 'sw1', due_at: ts(now - 1), due_reason: 'syslog', last_started_at: ts(now - 1),
        lease_owner: 'host:1:ab', lease_until: ts(now + 3599))
      seed('backup', 'fw1', due_at: ts(now + 50), due_reason: 'retry', last_started_at: ts(now - 30), last_finished_at: ts(now - 10),
        last_failed: true, consecutive_failures: 3, last_error: 'fetch: timed out')
      seed('audit', 'rt1', due_at: ts(now - 256), due_reason: 'schedule', signal_window_started_at: ts(now - 10))
    end

    it 'prints a table and exits 1' do
      expect(status).to eq(1)
      expect(table.first).to eq(['WORKFLOW', 'NODE', 'STATUS', 'DUE', 'REASON', 'LAST RUN', 'RESULT'])
      expect(table.drop(1).map { it.first(3) }).to eq([%w[audit rt1 overdue], %w[backup fw1 waiting], %w[backup rt1 waiting], %w[backup sw1 running]])
      expect(table.fetch(1)).to include('-', match(/\(4m1[56]s ago\)\z/), start_with('signal pending since '))
      expect(table.fetch(2)).to include(match(/\(in (49|50)s\)\z/), 'retry', match(/\(20\.0s\)\z/), 'failed ×3', 'fetch: timed out')
      expect(table.fetch(3)).to include(match(/\(in 8m5[12]s\)\z/), match(/\(3\.4s\)\z/), 'ok')
      expect(table.fetch(4)).to include(match(/\A\d\d:\d\d:\d\dZ\z/), match(/\(running\)\z/), start_with('lease host:1:ab until '))
    end

    it 'filters by workflow, node and failure' do
      status('-w', 'backup', '--only', 'rt1,fw1')
      expect(table.drop(1).map { it.first(2) }).to eq([%w[backup fw1], %w[backup rt1]])
      out.truncate(0)
      out.rewind
      expect(status('--failing')).to eq(1)
      expect(table.drop(1).map { it.first(2) }).to eq([%w[backup fw1]])
    end

    it 'prints ProtoJSON lines' do
      status('--json', '-w', 'audit')
      expect(out.string.lines.map { JSON.parse(it) }).to contain_exactly(include('workflow' => 'audit', 'node' => 'rt1', 'due_reason' => 'schedule'))
    end
  end

  it 'exits 0 when nothing is failing or overdue' do
    seed('backup', 'rt1', due_at: ts(now - 10), last_started_at: ts(now - 3600), last_finished_at: ts(now - 3590))
    expect(status).to eq(0)
    expect(table.fetch(1).first(3)).to eq(%w[backup rt1 due])
  end

  it 'refuses a workflow not orchestrated' do
    expect { status('-w', 'nope') }.to raise_error(Glazed::Error, /not orchestrated workflows: nope/)
  end
end
