# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

RSpec.shared_examples 'a conditional storage' do
  it 'reports conditional support' do
    expect(storage).to be_conditional
  end

  it 'has no version for a missing key' do
    expect(storage.version_of('state/db')).to be_nil
    expect(storage.read_versioned('state/db')).to be_nil
  end

  it 'creates a missing key only when no version is expected' do
    version = storage.write_if(key: 'state/db', content: 'v1', expected_version: nil)
    expect(storage.version_of('state/db')).to eq(version)
    expect(storage.read_versioned('state/db')).to have_attributes(content: 'v1', version:)
    expect { storage.write_if(key: 'state/db', content: 'v2', expected_version: nil) }.to raise_error(Glazed::Storages::Base::Conflict)
  end

  it 'replaces the expected version and refuses a stale one' do
    first = storage.write_if(key: 'state/db', content: 'v1', expected_version: nil)
    second = storage.write_if(key: 'state/db', content: 'v2', expected_version: first)
    expect(second).not_to eq(first)
    expect { storage.write_if(key: 'state/db', content: 'v3', expected_version: first) }.to raise_error(Glazed::Storages::Base::Conflict)
    expect(storage.read_versioned('state/db')&.content).to eq('v2')
  end

  it 'refuses a version for a missing key' do
    expect { storage.write_if(key: 'state/db', content: 'v1', expected_version: 'x') }.to raise_error(Glazed::Storages::Base::Conflict)
  end

  it 'rejects unsafe keys' do
    expect { storage.version_of('../db') }.to raise_error(Glazed::Storages::Base::InvalidKey)
    expect { storage.write_if(key: '../db', content: '', expected_version: nil) }.to raise_error(Glazed::Storages::Base::InvalidKey)
  end
end
