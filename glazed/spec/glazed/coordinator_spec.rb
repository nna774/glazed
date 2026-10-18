# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/coordinator'
require 'glazed/state_backends/sqlite'
require 'glazed/storages/memory'

RSpec.describe Glazed::Coordinator do
  let(:t0) { Time.at(1_800_000_000) }
  let(:clock) { [t0] }
  let(:backend) { Glazed::StateBackends::Sqlite.new(storage: Glazed::Storages::Memory.new, key: 'state') }
  let(:events) { [] }
  let(:settings) do
    Glazed::Proto::V1::Orchestrator.new(
      workflows: {'backup' => {schedule: {interval: {seconds: 3600}, retry_interval: {seconds: 600}}, batch_size: 2, lease: {seconds: 600}}},
    )
  end
  let(:coordinator) do
    described_class.new(settings:, backend:, listener: ->(event) { events << event }, clock: -> { clock.fetch(0) }, random: Random.new(1), owner: 'me')
  end

  after { backend.close }

  def advance(seconds) = clock[0] += seconds
  def nodes(*names) = names.map { Glazed::Proto::V1::Node.new(name: it) }
  def inventory(*names) = nodes(*names).to_h { [it.name, it] }
  def record(node) = backend.list('backup').find { it.node == node }

  describe '#sync_inventory' do
    it 'adds new nodes due now and deletes nodes gone' do
      coordinator.sync_inventory(nodes('rt1', 'rt2'))
      coordinator.sync_inventory(nodes('rt2', 'rt3'))
      expect(backend.list('backup').map { [it.node, it.due_reason] }).to eq([%w[rt2 inventory], %w[rt3 inventory]])
      expect(events.last).to include(workflow: 'backup', message: 'inventory changed', added: ['rt3'], removed: ['rt1'])
    end

    it 'reports nothing when the inventory is unchanged' do
      coordinator.sync_inventory(nodes('rt1'))
      events.clear
      coordinator.sync_inventory(nodes('rt1'))
      expect(events).to be_empty
    end
  end

  describe '#signal' do
    let(:settings) do
      Glazed::Proto::V1::Orchestrator.new(workflows: {'backup' => {debounce: {delay: {seconds: 60}}}, 'audit' => {debounce: {delay: {seconds: 120}}}})
    end

    def signal(**fields) = Glazed::Proto::V1::Signal.new(source: 'syslog', **fields)

    it 'applies a signal to every workflow with its debounce' do
      result = coordinator.signal([signal(node: 'rt1')], nodes: nodes('rt1', 'rt2'))
      expect(result.transform_values { |records| records.transform_values { it.due_at.to_time } })
        .to eq('backup' => {'rt1' => t0 + 60}, 'audit' => {'rt1' => t0 + 120})
    end

    it 'expands a signal of every node to the chosen workflows' do
      result = coordinator.signal([signal(all_nodes: true, workflows: ['audit'], immediate: true)], nodes: nodes('rt1', 'rt2'))
      expect(result.keys).to eq(['audit'])
      expect(backend.list('audit').map { [it.node, it.due_at.to_time, it.due_reason] }).to eq([['rt1', t0, 'syslog'], ['rt2', t0, 'syslog']])
    end

    it 'skips unknown nodes and workflows' do
      expect(coordinator.signal([signal(node: 'nope'), signal(node: 'rt1', workflows: ['gone'])], nodes: nodes('rt1'))).to be_empty
      expect(events).to contain_exactly(include(message: 'signal for unknown nodes skipped', nodes: ['nope']),
        include(message: 'signal for workflows not orchestrated skipped', workflows: ['gone']))
    end
  end

  describe '#claim' do
    it 'leases due nodes up to the batch size' do
      coordinator.sync_inventory(nodes('rt1', 'rt2', 'rt3'))
      owner, names = coordinator.claim('backup')
      expect(owner).to start_with('me:')
      expect(names).to eq(%w[rt1 rt2])
      expect(record('rt1').to_h).to include(lease_owner: owner, lease_until: {seconds: t0.to_i + 600})
      expect(coordinator.claim('backup').last).to eq(['rt3'])
    end

    it 'claims nothing when nothing is due' do
      expect(coordinator.claim('backup').last).to be_empty
    end

    it 'refuses a workflow not orchestrated' do
      expect { coordinator.claim('audit') }.to raise_error(ArgumentError, /not orchestrated/)
    end
  end

  describe '#complete' do
    it 'schedules the next run of each node by its outcome' do
      coordinator.sync_inventory(nodes('rt1', 'rt2'))
      owner, names = coordinator.claim('backup')
      advance(10)
      coordinator.complete('backup', owner:, names:, errors: {'rt2' => 'fetch: timeout'}, nodes: inventory('rt1', 'rt2'))
      expect([record('rt1').lease_owner, record('rt1').due_reason, record('rt1').due_at.to_time]).to eq(['', 'schedule', t0 + 3610])
      expect(record('rt2').to_h).to include(last_failed: true, last_error: 'fetch: timeout', due_at: {seconds: t0.to_i + 610})
    end

    it 'leaves records leased to another batch' do
      coordinator.sync_inventory(nodes('rt1'))
      coordinator.claim('backup')
      coordinator.complete('backup', owner: 'other', names: ['rt1'], errors: {}, nodes: inventory('rt1'))
      expect(record('rt1').lease_owner).to start_with('me:')
    end
  end

  describe 'schedule_rules' do
    let(:settings) do
      Glazed::Proto::V1::Orchestrator.new(
        workflows: {
          'backup' => {
            schedule: {interval: {seconds: 3600}},
            debounce: {delay: {seconds: 60}},
            schedule_rules: [
              {match: {name_regexp: '.*\\.venue'}, schedule: {interval: {seconds: 604_800}}, debounce: {delay: {seconds: 300}}},
              {match: {names: ['rt3']}, schedule: {interval: {seconds: 86_400}}},
            ],
          },
        },
      )
    end
    let(:inventory_nodes) { nodes('rt1.hnd', 'rt2.venue', 'rt3') }

    it 'schedules the next run of each node by the rule matching it' do
      coordinator.sync_inventory(inventory_nodes)
      owner, names = coordinator.claim('backup')
      coordinator.complete('backup', owner:, names:, errors: {}, nodes: inventory('rt1.hnd', 'rt2.venue', 'rt3'))
      expect(names.to_h { [it, record(it).due_at.to_time - t0] }).to eq('rt1.hnd' => 3600, 'rt2.venue' => 604_800, 'rt3' => 86_400)
    end

    it 'falls back to the workflow schedule for a node missing from the inventory' do
      coordinator.sync_inventory(inventory_nodes)
      owner, names = coordinator.claim('backup')
      coordinator.complete('backup', owner:, names:, errors: {}, nodes: {})
      expect(record('rt2.venue').due_at.to_time).to eq(t0 + 3600)
    end

    it 'debounces a signal by the rule matching the node, and the workflow when the rule sets none' do
      result = coordinator.signal([Glazed::Proto::V1::Signal.new(source: 'syslog', all_nodes: true)], nodes: inventory_nodes)
      expect(result.fetch('backup').transform_values { it.due_at.to_time - t0 }).to eq('rt1.hnd' => 60, 'rt2.venue' => 300, 'rt3' => 60)
    end
  end

  describe '#release' do
    it 'gives up leases without recording a run' do
      coordinator.sync_inventory(nodes('rt1'))
      owner, names = coordinator.claim('backup')
      coordinator.release('backup', owner:, names:)
      expect([record('rt1').lease_owner, record('rt1').due_reason]).to eq(['', 'inventory'])
      expect(record('rt1').last_finished_at).to be_nil
    end
  end

  describe '#next_due' do
    it 'is nil without records' do
      expect(coordinator.next_due).to be_nil
    end

    it 'is the earliest due date, or lease end of a leased node' do
      coordinator.sync_inventory(nodes('rt1', 'rt2', 'rt3'))
      coordinator.claim('backup')
      expect(coordinator.next_due).to eq(t0)
      coordinator.claim('backup')
      expect(coordinator.next_due).to eq(t0 + 600)
    end
  end
end
