# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/orchestrator'
require 'glazed/state_backends/sqlite'
require 'glazed/storages/memory'

RSpec.describe Glazed::Orchestrator do
  let(:t0) { Time.at(1_800_000_000) }
  let(:clock) { [t0] }
  let(:backend) { Glazed::StateBackends::Sqlite.new(storage: Glazed::Storages::Memory.new, key: 'state') }
  let(:inventory) { %w[rt1 rt2].map { Glazed::Proto::V1::Node.new(name: it) } }
  let(:runs) { [] }
  let(:events) { [] }
  let(:failing) { [] }
  let(:settings) do
    Glazed::Proto::V1::Orchestrator.new(
      workflows: {'backup' => {schedule: {interval: {seconds: 3600}, retry_interval: {seconds: 600}}, debounce: {delay: {seconds: 60}, max_wait: {seconds: 300}}}},
      poll: {seconds: 30},
      inventory_refresh: {seconds: 300},
    )
  end
  let(:step) do
    seen = runs
    broken = failing
    Class.new(Glazed::Steps::BatchStep) do
      define_method(:call) do |batch|
        raise Glazed::Error, 'push rejected' if broken.include?(:batch)

        seen << batch.nodes.map { it.node.name }
        batch
      end
    end.new(name: 'publish')
  end
  let(:node_step) do
    broken = failing
    Class.new(Glazed::Steps::NodeStep) do
      define_method(:call) do |state|
        raise Glazed::Error, 'timeout' if broken.include?(state.node.name)

        state
      end
    end.new(name: 'fetch')
  end
  let(:orchestrator) do
    described_class.new(
      settings:, workflows: {'backup' => Glazed::Workflow.new(steps: [node_step, step])}, backend:, inventory: -> { inventory }, jobs: 2,
      listener: ->(event) { events << event }, clock: -> { clock.fetch(0) }, random: Random.new(1),
    )
  end

  after { backend.close }

  def advance(seconds) = clock[0] += seconds
  def record(node) = backend.list('backup').find { it.node == node }
  def signal(node, **fields) = described_class.signal(backend:, workflow: 'backup', signals: [Glazed::Proto::V1::Signal.new(node:, source: 'manual', **fields)], debounce: settings.workflows['backup'].debounce, now: clock[0])

  it 'runs nodes new to the inventory together, then every interval' do
    orchestrator.tick
    expect(runs).to eq([%w[rt1 rt2]])
    expect(record('rt1').to_h).to include(due_reason: 'schedule', due_at: {seconds: t0.to_i + 3600})
    expect(record('rt1').lease_owner).to eq('')

    advance(3599)
    orchestrator.tick
    expect(runs.size).to eq(1)
    advance(1)
    orchestrator.tick
    expect(runs.size).to eq(2)
  end

  it 'runs a signalled node after the debounce delay' do
    orchestrator.tick
    advance(100)
    signal('rt2')
    advance(59)
    orchestrator.tick
    expect(runs.size).to eq(1)
    advance(1)
    orchestrator.tick
    expect(runs.last).to eq(['rt2'])
  end

  it 'waits until the next due date, at most the poll interval' do
    orchestrator.tick
    signal('rt1')
    expect(orchestrator.tick).to eq(30.0)
    advance(40)
    expect(orchestrator.tick).to eq(20.0)
  end

  it 'retries failed nodes after the retry interval' do
    failing << 'rt1'
    orchestrator.tick
    expect(runs).to eq([['rt2']])
    expect(record('rt1').to_h).to include(last_failed: true, last_error: 'fetch: timeout', due_reason: 'retry', due_at: {seconds: t0.to_i + 600})
  end

  it 'fails every node of a batch whose batch step fails, and keeps running' do
    failing << :batch
    orchestrator.tick
    expect(backend.list('backup').map { [it.node, it.last_error] }).to eq([['rt1', 'Glazed::Error: push rejected'], ['rt2', 'Glazed::Error: push rejected']])
    expect(events).to include(include(level: 'error', message: 'batch failed: push rejected'))
  end

  it 'follows inventory changes' do
    orchestrator.tick
    inventory.replace([Glazed::Proto::V1::Node.new(name: 'rt2'), Glazed::Proto::V1::Node.new(name: 'rt3')])
    advance(300)
    orchestrator.tick
    expect(backend.list('backup').map(&:node)).to eq(%w[rt2 rt3])
    expect(runs.last).to eq(['rt3'])
    expect(events).to include(include(message: 'inventory changed', added: ['rt3'], removed: ['rt1']))
  end

  it 'keeps the previous inventory when reloading fails' do
    orchestrator.tick
    orchestrator.instance_variable_set(:@inventory, -> { raise Glazed::Error, 'netbox down' })
    advance(3600)
    orchestrator.tick
    expect(runs.last).to eq(%w[rt1 rt2])
    expect(events).to include(include(level: 'error', message: /netbox down/))
  end

  it 'skips nodes leased by another orchestrator until the lease expires' do
    orchestrator.tick
    advance(3600)
    backend.update('backup', 'rt1') { Glazed::Orchestrator::Policy.claim(it, owner: 'other', now: clock[0], lease_seconds: 600) }
    orchestrator.tick
    expect(runs.last).to eq(['rt2'])
    advance(600)
    orchestrator.tick
    expect(runs.last).to eq(['rt1'])
  end

  it 'releases leases when interrupted' do
    interrupting = Class.new(Glazed::Steps::BatchStep) { define_method(:call) { |_batch| raise Interrupt } }.new(name: 'publish')
    interrupted = described_class.new(settings:, workflows: {'backup' => Glazed::Workflow.new(steps: [interrupting])}, backend:, inventory: -> { inventory }, jobs: 1,
      clock: -> { clock.fetch(0) })
    expect { interrupted.tick }.to raise_error(Interrupt)
    expect(backend.list('backup').map(&:lease_owner)).to eq(['', ''])
    expect(backend.list_due('backup', now: clock[0]).size).to eq(2)
  end

  it 'stops after the current batch when asked' do
    orchestrator.stop
    orchestrator.run
    expect(runs).to eq([%w[rt1 rt2]])
    expect(events.last).to include(message: 'orchestrator stopped')
  end

  it 'reloads the inventory when asked' do
    orchestrator.tick
    inventory << Glazed::Proto::V1::Node.new(name: 'rt3')
    orchestrator.reload_inventory
    subject = orchestrator
    events.define_singleton_method(:<<) do |event|
      super(event).tap { subject.stop if event[:message] == 'batch finished' }
    end
    subject.run
    expect(runs.last).to eq(['rt3'])
  end

  it 'reports every inventory load, changed or not' do
    orchestrator.tick
    orchestrator.reload_inventory
    subject = orchestrator
    events.define_singleton_method(:<<) do |event|
      super(event).tap { subject.stop if event[:message] == 'inventory loaded' }
    end
    subject.run
    expect(events.select { it[:message] == 'inventory loaded' }).to eq([{level: 'info', message: 'inventory loaded', nodes: 2}] * 2)
    expect(events.count { it[:message] == 'inventory changed' }).to eq(1)
  end

  it 'runs each workflow on its own schedule from one state' do
    audits = []
    audit = Class.new(Glazed::Steps::BatchStep) do
      define_method(:call) do |batch|
        audits << batch.nodes.map { it.node.name }
        batch
      end
    end.new(name: 'audit')
    settings.workflows['audit'] = Glazed::Proto::V1::Orchestration.new(schedule: {interval: {seconds: 600}})
    both = described_class.new(
      settings:, workflows: {'backup' => Glazed::Workflow.new(steps: [step]), 'audit' => Glazed::Workflow.new(steps: [audit])},
      backend:, inventory: -> { inventory }, jobs: 1, clock: -> { clock.fetch(0) },
    )
    both.tick
    expect([runs, audits]).to eq([[%w[rt1 rt2]], [%w[rt1 rt2]]])
    advance(600)
    both.tick
    expect([runs.size, audits.size]).to eq([1, 2])
    expect(backend.list('audit').map(&:node)).to eq(%w[rt1 rt2])
  end

  it 'refuses workflows other than those the settings orchestrate' do
    expect { described_class.new(settings:, workflows: {}, backend:, inventory: -> { [] }, jobs: 1) }.to raise_error(ArgumentError)
  end

  it 'loads the inventory before anything, failing when it cannot' do
    broken = described_class.new(settings:, workflows: {'backup' => Glazed::Workflow.new(steps: [step])}, backend:, inventory: -> { raise Glazed::Error, 'no' }, jobs: 1)
    expect { broken.tick }.to raise_error(Glazed::Error, 'no')
  end
end
