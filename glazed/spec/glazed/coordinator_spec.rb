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
      workflows: {'backup' => {schedule: {interval_seconds: 3600, retry_interval_seconds: 600}, batch_size: 2, lease_seconds: 600}},
    )
  end
  let(:coordinator) do
    described_class.new(settings:, backend:, listener: ->(event) { events << event }, clock: -> { clock.fetch(0) }, random: Random.new(1), owner: 'me')
  end

  after { backend.close }

  def advance(seconds) = clock[0] += seconds
  def record(node) = backend.list('backup').find { it.node == node }

  describe '#sync_inventory' do
    it 'adds new nodes due now and deletes nodes gone' do
      coordinator.sync_inventory(%w[rt1 rt2])
      coordinator.sync_inventory(%w[rt2 rt3])
      expect(backend.list('backup').map { [it.node, it.due_reason] }).to eq([%w[rt2 inventory], %w[rt3 inventory]])
      expect(events.last).to include(workflow: 'backup', message: 'inventory changed', added: ['rt3'], removed: ['rt1'])
    end

    it 'reports nothing when the inventory is unchanged' do
      coordinator.sync_inventory(%w[rt1])
      events.clear
      coordinator.sync_inventory(%w[rt1])
      expect(events).to be_empty
    end
  end

  describe '#claim' do
    it 'leases due nodes up to the batch size' do
      coordinator.sync_inventory(%w[rt1 rt2 rt3])
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
      coordinator.sync_inventory(%w[rt1 rt2])
      owner, names = coordinator.claim('backup')
      advance(10)
      coordinator.complete('backup', owner:, names:, errors: {'rt2' => 'fetch: timeout'})
      expect([record('rt1').lease_owner, record('rt1').due_reason, record('rt1').due_at.to_time]).to eq(['', 'schedule', t0 + 3610])
      expect(record('rt2').to_h).to include(last_failed: true, last_error: 'fetch: timeout', due_at: {seconds: t0.to_i + 610})
    end

    it 'leaves records leased to another batch' do
      coordinator.sync_inventory(%w[rt1])
      coordinator.claim('backup')
      coordinator.complete('backup', owner: 'other', names: ['rt1'], errors: {})
      expect(record('rt1').lease_owner).to start_with('me:')
    end
  end

  describe '#release' do
    it 'gives up leases without recording a run' do
      coordinator.sync_inventory(%w[rt1])
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
      coordinator.sync_inventory(%w[rt1 rt2 rt3])
      coordinator.claim('backup')
      expect(coordinator.next_due).to eq(t0)
      coordinator.claim('backup')
      expect(coordinator.next_due).to eq(t0 + 600)
    end
  end
end
