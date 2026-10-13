# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'tmpdir'
require 'glazed/state_backends'
require 'glazed/state_backends/sqlite'
require 'glazed/storages/memory'

RSpec.describe Glazed::StateBackends::Sqlite do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:now) { Time.at(1_800_000_000) }

  def schedule(node, due_at: now) = Glazed::Proto::V1::NodeSchedule.new(workflow: 'backup', node:, due_at: Google::Protobuf::Timestamp.from_time(due_at))

  context 'with a local file' do
    let(:path) { File.join(@dir, 'state', 'db.sqlite3') }
    let(:backend) { described_class.new(path:) }

    after { backend.close }

    it_behaves_like 'a state backend'

    it 'shares the file with another backend' do
      backend.update('backup', 'rt1') { schedule('rt1') }
      other = described_class.new(path:)
      expect(other.list('backup').map(&:node)).to eq(['rt1'])
      other.close
    end

    it 'refuses a database of another schema version' do
      backend.list('backup')
      backend.close
      SQLite3::Database.new(path) { it.execute('update glazed_schema set version = 99') }
      expect { described_class.new(path:).list('backup') }.to raise_error(described_class::SchemaMismatch, /version 99/)
    end
  end

  context 'kept in a storage' do
    let(:storage) { Glazed::Storages::Memory.new }
    let(:events) { [] }
    let(:backend) { described_class.new(storage:, key: 'state/db', listener: ->(event) { events << event }) }

    after { backend.close }

    it_behaves_like 'a state backend'

    it 'uploads after a change only' do
      backend.list('backup')
      expect(storage.version_of('state/db')).to be_nil
      backend.update('backup', 'rt1') { schedule('rt1') }
      version = storage.version_of('state/db')
      expect(version).not_to be_nil
      backend.update('backup', 'rt1') { it }
      expect(storage.version_of('state/db')).to eq(version)
    end

    it 'reads changes uploaded by another backend' do
      other = described_class.new(storage:, key: 'state/db')
      backend.update('backup', 'rt1') { schedule('rt1') }
      other.update('backup', 'rt2') { schedule('rt2') }
      expect(backend.list('backup').map(&:node)).to eq(%w[rt1 rt2])
      other.close
    end

    it 'redoes a change on the newer copy when another backend uploaded first' do
      other = described_class.new(storage:, key: 'state/db')
      calls = 0
      backend.update('backup', 'rt1') do |record|
        calls += 1
        other.update('backup', 'rt2') { schedule('rt2') } if calls == 1
        record || schedule('rt1')
      end
      expect(calls).to eq(2)
      expect(other.list('backup').map(&:node)).to eq(%w[rt1 rt2])
      expect(events).to contain_exactly(include(level: 'info', message: /redoing the change/))
      other.close
    end

    it 'gives up when conflicts persist' do
      allow(storage).to receive(:write_if).and_raise(Glazed::Storages::Base::Conflict)
      stub_const("#{described_class}::MAX_ATTEMPTS", 2)
      expect { backend.update('backup', 'rt1') { schedule('rt1') } }.to raise_error(Glazed::Storages::Base::Conflict)
      expect(storage).to have_received(:write_if).twice
    end

    it 'drops a change whose upload failed' do
      allow(storage).to receive(:write_if).and_raise(Glazed::Error, 'network')
      expect { backend.update('backup', 'rt1') { schedule('rt1') } }.to raise_error(Glazed::Error, 'network')
      expect(backend.list('backup')).to be_empty
    end

    it 'refuses a storage without conditional writes' do
      expect { described_class.new(storage: instance_double(Glazed::Storages::Base, conditional?: false), key: 'x') }.to raise_error(ArgumentError, /conditional/)
    end
  end

  it 'requires either a path, or a storage and key' do
    expect { described_class.new }.to raise_error(ArgumentError)
    expect { described_class.new(path: 'x', key: 'y') }.to raise_error(ArgumentError)
    expect { described_class.new(key: 'y') }.to raise_error(ArgumentError)
  end

  it 'is built from a config naming a storage' do
    context = Glazed::StepContext.new(storages: {'state' => Glazed::Storages::Memory.new})
    config = Glazed::Proto::V1::StateBackendConfig.new(sqlite: {storage: 'state', key: 'db'})
    backend = Glazed::StateBackends.build(config, context:)
    expect(backend).to be_a(described_class)
    backend.close
  end

  it 'rejects a config setting both a path and a storage' do
    config = Glazed::Proto::V1::StateBackendConfig.new(sqlite: {path: 'x', storage: 'state', key: 'db'})
    expect { Glazed::StateBackends.build(config, context: Glazed::StepContext.new(storages: {})) }.to raise_error(Glazed::InvalidMessage, /path, or storage and key/)
  end
end
