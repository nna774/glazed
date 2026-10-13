# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/storages'
require 'glazed/storages/s3'

RSpec.describe Glazed::Storages::S3 do
  let(:client) { Aws::S3::Client.new(stub_responses: true) }
  let(:storage) { described_class.new(bucket: 'netconf', prefix: 'raw/', client:) }

  it 'puts objects under the prefix and points at their versions' do
    client.stub_responses(:put_object, [{version_id: 'v1'}, {version_id: 'v2'}])
    pointers = storage.write_all([['core/rt1', "a\n"], ['core/rt2', "b\n"]], message: 'batch')
    expect(pointers.map { it.s3.to_h }).to eq([
      {bucket: 'netconf', key: 'raw/core/rt1', version_id: 'v1'},
      {bucket: 'netconf', key: 'raw/core/rt2', version_id: 'v2'},
    ])
    expect(client.api_requests.map { it[:params].slice(:key, :body, :content_type) }).to eq([
      {key: 'raw/core/rt1', body: "a\n", content_type: 'text/plain; charset=utf-8'},
      {key: 'raw/core/rt2', body: "b\n", content_type: 'text/plain; charset=utf-8'},
    ])
  end

  it 'leaves the version empty for an unversioned bucket' do
    client.stub_responses(:put_object, {version_id: nil})
    expect(storage.write(key: 'rt1', content: '', message: 'x').s3.version_id).to eq('')
  end

  it 'reads the pointed version' do
    client.stub_responses(:get_object, {body: "hostname rt1\n"})
    pointer = Glazed::Proto::V1::Pointer.new(s3: {bucket: 'netconf', key: 'raw/rt1', version_id: 'v1'})
    expect(storage.read(pointer)).to eq("hostname rt1\n")
    expect(client.api_requests.last[:params]).to include(bucket: 'netconf', key: 'raw/rt1', version_id: 'v1')
  end

  it 'reads the latest content without a version' do
    client.stub_responses(:get_object, {body: 'x'})
    storage.read(Glazed::Proto::V1::Pointer.new(s3: {bucket: 'netconf', key: 'raw/rt1'}))
    expect(client.api_requests.last[:params]).to eq(bucket: 'netconf', key: 'raw/rt1', checksum_mode: 'ENABLED')
  end

  it 'rejects unsafe keys before writing anything' do
    expect { storage.write_all([['ok', ''], ['../x', '']], message: 'x') }.to raise_error(Glazed::Storages::Base::InvalidKey)
    expect(client.api_requests).to be_empty
  end

  it 'is found by Storages.build from a config' do
    config = Glazed::Proto::V1::StorageConfig.new(s3: {bucket: 'netconf', prefix: 'raw/'})
    expect(Glazed::Storages.build(config)).to be_a(described_class).and(have_attributes(bucket: 'netconf', prefix: 'raw/'))
  end

  it 'builds an SDK client in the configured region' do
    client = Aws::S3::Client.new(stub_responses: true)
    allow(Aws::S3::Client).to receive(:new).with(region: 'ap-northeast-1').and_return(client)
    storage = described_class.new(bucket: 'netconf', region: 'ap-northeast-1')
    storage.write(key: 'rt1', content: '', message: 'x')
    expect(client.api_requests.size).to eq(1)
  end
end
