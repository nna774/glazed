# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/coordinator/task_runner'
require 'glazed/state_backends/sqlite'
require 'glazed/storages/memory'

RSpec.describe Glazed::Coordinator::TaskRunner do
  let(:t0) { Time.at(1_800_000_000) }
  let(:clock) { [t0] }
  let(:backend) { Glazed::StateBackends::Sqlite.new(storage: Glazed::Storages::Memory.new, key: 'state') }
  let(:inventory) { %w[rt1 sw1].map { Glazed::Proto::V1::Node.new(name: it) } }
  let(:events) { [] }
  let(:published) { [] }
  let(:failing) { [] }
  let(:settings) do
    Glazed::Proto::V1::Orchestrator.new(
      workflows: {'backup' => {schedule: {interval_seconds: 86_400, retry_interval_seconds: 600}, debounce: {delay_seconds: 60, max_wait_seconds: 600}}},
      poll_seconds: 30,
    )
  end
  let(:fetch) do
    broken = failing
    Class.new(Glazed::Steps::NodeStep) do
      define_method(:call) do |state|
        raise Glazed::Error, 'timeout' if broken.include?(state.node.name)

        state
      end
    end.new(name: 'fetch')
  end
  let(:publish) do
    seen = published
    broken = failing
    Class.new(Glazed::Steps::BatchStep) do
      define_method(:call) do |batch|
        raise Glazed::Error, 'push rejected' if broken.include?(:batch)

        seen << batch.nodes.map { it.node.name }
        batch
      end
    end.new(name: 'publish')
  end
  let(:coordinator) do
    Glazed::Coordinator.new(settings:, backend:, listener: ->(event) { events << event }, clock: -> { clock.fetch(0) }, random: Random.new(1))
  end
  let(:runner) do
    described_class.new(coordinator:, workflows: {'backup' => Glazed::Workflow.new(steps: [fetch, publish])}, inventory: -> { inventory },
      listener: ->(event) { events << event })
  end

  after { backend.close }

  def advance(seconds) = clock[0] += seconds
  def task(**fields) = Glazed::Proto::V1::CoordinatorTask.new(**fields)
  def record(node) = backend.list('backup').find { it.node == node }

  def check(token, cycle: 0, signals: [])
    runner.perform(task(check: {token:, cycle:, signals:})).wait_until&.to_time
  end

  def syslog(node) = Glazed::Proto::V1::Signal.new(node:, source: 'syslog', received_at: Google::Protobuf::Timestamp.from_time(clock[0]))

  # What the state machine does after Sleep, for every workflow.
  def run_cycle
    batch = runner.perform(task(prepare: {})).batches['backup']
    return batch if batch.nodes.empty?

    nodes = batch.nodes.map { runner.perform(task(node_step: {workflow: 'backup', step: 'fetch', outcome: it})) }
    batch = runner.perform(task(batch_step: {step: 'publish', batch: Glazed::Proto::V1::Batch.new(workflow: 'backup', owner: batch.owner, nodes:)}))
    runner.perform(task(complete: {batch:}))
  end

  it 'debounces signals arriving before, during and after a run into one waiter' do
    daily = Glazed::Proto::V1::Signal.new(all_nodes: true, source: 'daily', immediate: true)
    expect(check('E1', signals: [daily])).to eq(t0)

    batch = runner.perform(task(prepare: {})).batches['backup']
    expect(batch.nodes.map { it.state.node.name }).to eq(%w[rt1 sw1])

    advance(20)
    expect(check('E2', signals: [syslog('sw1')])).to be_nil
    advance(20)
    expect(check('E3', signals: [syslog('sw1')])).to be_nil

    advance(15)
    nodes = batch.nodes.map { runner.perform(task(node_step: {workflow: 'backup', step: 'fetch', outcome: it})) }
    done = runner.perform(task(batch_step: {step: 'publish', batch: Glazed::Proto::V1::Batch.new(workflow: 'backup', owner: batch.owner, nodes:)}))
    runner.perform(task(complete: {batch: done}))
    expect(published).to eq([%w[rt1 sw1]])
    expect([record('sw1').due_at.to_time, record('sw1').due_reason]).to eq([t0 + 100, 'syslog'])
    expect(check('E1', cycle: 1)).to eq(t0 + 100)

    advance(15)
    expect(check('E4', signals: [syslog('sw1')])).to be_nil
    expect(record('sw1').due_at.to_time).to eq(t0 + 130)

    advance(30)
    expect(run_cycle.nodes).to be_empty
    expect(check('E1', cycle: 2)).to eq(t0 + 130)

    advance(30)
    run_cycle
    expect(published.last).to eq(['sw1'])
    expect(check('E1', cycle: 3)).to eq(t0 + 55 + 86_400)
  end

  it 'records failures of nodes and batch steps' do
    failing << 'rt1'
    check('E1')
    run_cycle
    expect(published).to eq([['sw1']])
    expect(record('rt1').to_h).to include(last_failed: true, last_error: 'fetch: timeout', due_reason: 'retry')
    expect(record('sw1').last_failed).to be(false)

    failing.replace([:batch])
    advance(600)
    expect(run_cycle.error).to eq('publish: push rejected')
    expect(record('rt1').to_h).to include(last_error: 'publish: push rejected', consecutive_failures: 2)
  end

  it 'passes a failed batch through later batch steps' do
    batch = Glazed::Proto::V1::Batch.new(workflow: 'backup', owner: 'x', error: 'publish: no')
    expect(runner.perform(task(batch_step: {step: 'publish', batch:}))).to eq(batch)
  end

  it 'refuses unknown steps and steps of the other kind' do
    outcome = Glazed::Proto::V1::NodeOutcome.new(state: {node: {name: 'rt1'}})
    expect { runner.perform(task(node_step: {workflow: 'backup', step: 'nope', outcome:})) }.to raise_error(ArgumentError, /no step "nope"/)
    expect { runner.perform(task(node_step: {workflow: 'backup', step: 'publish', outcome:})) }.to raise_error(ArgumentError, /not a Glazed::Steps::NodeStep/)
    expect { runner.perform(task(node_step: {workflow: 'audit', step: 'fetch', outcome:})) }.to raise_error(ArgumentError, /not orchestrated/)
  end

  it 'refuses a task without a kind' do
    expect { runner.perform(task) }.to raise_error(Glazed::InvalidMessage)
  end
end
