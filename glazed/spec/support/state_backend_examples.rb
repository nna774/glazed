# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/proto'

# Expects `backend` to be an empty state backend.
RSpec.shared_examples 'a state backend' do
  let(:now) { Time.at(1_800_000_000) }

  def schedule(node, due_at:, workflow: 'backup', **fields)
    Glazed::Proto::V1::NodeSchedule.new(workflow:, node:, due_at: Google::Protobuf::Timestamp.from_time(due_at), **fields)
  end

  it 'creates, replaces and deletes records' do
    backend.update('backup', 'rt1') { |record| record || schedule('rt1', due_at: now, due_reason: 'inventory') }
    expect(backend.list('backup').map(&:to_h)).to contain_exactly(include(node: 'rt1', due_reason: 'inventory'))

    backend.update('backup', 'rt1') { |record| schedule('rt1', due_at: record.due_at.to_time + 60, due_reason: 'schedule') }
    expect(backend.list('backup').map { [it.due_reason, it.due_at.to_time] }).to eq([['schedule', now + 60]])

    expect(backend.update('backup', 'rt1') { nil }).to be_nil
    expect(backend.list('backup')).to be_empty
  end

  it 'updates several nodes and returns the records held afterwards' do
    backend.update('backup', 'gone') { schedule('gone', due_at: now) }
    result = backend.update_all('backup', %w[rt1 rt2 gone]) do |node, record|
      schedule(node, due_at: now) unless record
    end
    expect(result.keys).to contain_exactly('rt1', 'rt2')
    expect(backend.list('backup').map(&:node)).to eq(%w[rt1 rt2])
  end

  it 'keeps workflows apart' do
    backend.update('backup', 'rt1') { schedule('rt1', due_at: now) }
    backend.update('audit', 'rt1') { schedule('rt1', due_at: now, workflow: 'audit') }
    expect(backend.list('backup').map(&:workflow)).to eq(['backup'])
    expect(backend.list_due('audit', now:).map(&:workflow)).to eq(['audit'])
  end

  it 'lists records due and not leased, earliest first' do
    backend.update_all('backup', %w[late early future leased expired]) do |node, _|
      case node
      when 'late' then schedule(node, due_at: now - 10)
      when 'early' then schedule(node, due_at: now - 20)
      when 'future' then schedule(node, due_at: now + 1)
      when 'leased' then schedule(node, due_at: now - 30, lease_owner: 'x', lease_until: Google::Protobuf::Timestamp.from_time(now + 1))
      else schedule(node, due_at: now - 5, lease_owner: 'x', lease_until: Google::Protobuf::Timestamp.from_time(now))
      end
    end
    expect(backend.list_due('backup', now:).map(&:node)).to eq(%w[early late expired])
    expect(backend.list_due('backup', now:, limit: 2).map(&:node)).to eq(%w[early late])
  end

  it 'refuses a record of another node' do
    expect { backend.update('backup', 'rt1') { schedule('rt2', due_at: now) } }.to raise_error(ArgumentError)
  end

  it 'refuses an invalid record' do
    expect { backend.update('backup', 'rt1') { Glazed::Proto::V1::NodeSchedule.new(workflow: 'backup', node: 'rt1') } }.to raise_error(Glazed::InvalidMessage)
  end
end
