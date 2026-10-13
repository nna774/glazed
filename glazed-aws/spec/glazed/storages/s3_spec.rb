# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'base64'
require 'digest'
require 'glazed/storages'
require 'glazed/storages/s3'

RSpec.describe Glazed::Storages::S3 do
  let(:client) { Aws::S3::Client.new(stub_responses: true) }
  let(:storage) { described_class.new(bucket: 'netconf', prefix: 'raw/', client:) }
  let(:message) { ->(_) { 'unused' } }

  def checksum(content) = Base64.strict_encode64(Digest::SHA256.digest(content))

  def requests(operation) = client.api_requests.select { it[:operation_name] == operation }.map { it[:params] }

  it 'creates a missing object only if it is still missing' do
    client.stub_responses(:head_object, 'NotFound')
    client.stub_responses(:put_object, {version_id: 'v1'})
    result = storage.write(key: 'core/rt1', content: "a\n", message: 'x')
    expect(result).to be_changed
    expect(result.pointer.s3.to_h).to eq(bucket: 'netconf', key: 'raw/core/rt1', version_id: 'v1')
    expect(requests(:put_object)).to contain_exactly(
      include(key: 'raw/core/rt1', body: "a\n", content_type: 'text/plain', checksum_sha256: checksum("a\n"), if_none_match: '*'),
    )
    expect(requests(:head_object)).to contain_exactly(include(key: 'raw/core/rt1', checksum_mode: 'ENABLED'))
  end

  it 'skips identical content and points at the existing version' do
    client.stub_responses(:head_object, {checksum_sha256: checksum("a\n"), version_id: 'v1', etag: '"e1"'})
    result = storage.write(key: 'rt1', content: "a\n", message: 'x')
    expect(result).not_to be_changed
    expect(result.pointer.s3.version_id).to eq('v1')
    expect(requests(:put_object)).to be_empty
  end

  it 'replaces changed content only if the checked version is still current' do
    client.stub_responses(:head_object, {checksum_sha256: checksum("old\n"), version_id: 'v1', etag: '"e1"'})
    client.stub_responses(:put_object, {version_id: 'v2'})
    result = storage.write(key: 'rt1', content: "new\n", message: 'x')
    expect(result).to be_changed
    expect(result.pointer.s3.version_id).to eq('v2')
    expect(requests(:put_object)).to contain_exactly(include(if_match: '"e1"'))
  end

  it 'replaces an object written without a checksum' do
    client.stub_responses(:head_object, {version_id: 'v1', etag: '"e1"'})
    client.stub_responses(:put_object, {version_id: 'v2'})
    expect(storage.write(key: 'rt1', content: "a\n", message: 'x')).to be_changed
  end

  it 'checks again when another writer got in between' do
    client.stub_responses(:head_object, [
      {checksum_sha256: checksum("old\n"), etag: '"e1"'},
      {checksum_sha256: checksum("other\n"), etag: '"e2"'},
    ])
    client.stub_responses(:put_object, ['PreconditionFailed', {version_id: 'v3'}])
    expect(storage.write(key: 'rt1', content: "new\n", message: 'x').pointer.s3.version_id).to eq('v3')
    expect(requests(:put_object).map { it[:if_match] }).to eq(['"e1"', '"e2"'])
  end

  it 'propagates errors of the existence check other than not found' do
    client.stub_responses(:head_object, 'AccessDenied')
    expect { storage.write(key: 'rt1', content: '', message: 'x') }.to raise_error(Aws::S3::Errors::AccessDenied)
    expect(requests(:put_object)).to be_empty
  end

  it 'gives up after repeated conflicts' do
    client.stub_responses(:head_object, {etag: '"e1"'})
    client.stub_responses(:put_object, 'PreconditionFailed')
    expect { storage.write(key: 'rt1', content: "a\n", message: 'x') }.to raise_error(Aws::S3::Errors::ServiceError)
    expect(requests(:put_object).size).to eq(described_class::MAX_ATTEMPTS)
  end

  it 'writes every file of a batch with its own result' do
    client.stub_responses(:head_object, [{checksum_sha256: checksum("a\n"), version_id: 'v1'}, 'NotFound'])
    client.stub_responses(:put_object, {version_id: 'v9'})
    results = storage.write_all([['rt1', "a\n"], ['rt2', "b\n"]], message:)
    expect(results.map { [it.pointer.s3.key, it.changed?] }).to eq([['raw/rt1', false], ['raw/rt2', true]])
  end

  it 'leaves the version empty for an unversioned bucket' do
    client.stub_responses(:head_object, 'NotFound')
    client.stub_responses(:put_object, {version_id: nil})
    expect(storage.write(key: 'rt1', content: '', message: 'x').pointer.s3.version_id).to eq('')
  end

  it 'reads the pointed version' do
    client.stub_responses(:get_object, {body: "hostname rt1\n"})
    pointer = Glazed::Proto::V1::Pointer.new(s3: {bucket: 'netconf', key: 'raw/rt1', version_id: 'v1'})
    expect(storage.read(pointer)).to eq("hostname rt1\n")
    expect(requests(:get_object).last).to include(bucket: 'netconf', key: 'raw/rt1', version_id: 'v1')
  end

  it 'reads the latest content without a version' do
    client.stub_responses(:get_object, {body: 'x'})
    storage.read(Glazed::Proto::V1::Pointer.new(s3: {bucket: 'netconf', key: 'raw/rt1'}))
    expect(requests(:get_object).last).not_to have_key(:version_id)
  end

  it 'rejects unsafe keys before writing anything' do
    expect { storage.write_all([['ok', ''], ['../x', '']], message:) }.to raise_error(Glazed::Storages::Base::InvalidKey)
    expect(client.api_requests).to be_empty
  end

  it 'is found by Storages.build from a config' do
    config = Glazed::Proto::V1::StorageConfig.new(s3: {bucket: 'netconf', prefix: 'raw/'})
    expect(Glazed::Storages.build(config)).to be_a(described_class).and(have_attributes(bucket: 'netconf', prefix: 'raw/'))
  end

  it 'builds an SDK client in the configured region' do
    built = Aws::S3::Client.new(stub_responses: true)
    built.stub_responses(:head_object, 'NotFound')
    allow(Aws::S3::Client).to receive(:new).with(region: 'ap-northeast-1').and_return(built)
    described_class.new(bucket: 'netconf', region: 'ap-northeast-1').write(key: 'rt1', content: '', message: 'x')
    expect(built.api_requests.map { it[:operation_name] }).to eq(%i[head_object put_object])
  end
end
