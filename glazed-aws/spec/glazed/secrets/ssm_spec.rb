# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/secrets/ssm'
require 'glazed/secrets_resolver'

RSpec.describe Glazed::Secrets::Ssm do
  let(:client) { Aws::SSM::Client.new(stub_responses: true) }
  let(:clock) { [100.0] }
  let(:source) { described_class.new(name: '/glazed/password', cache_seconds: 60, client:, clock: -> { clock.fetch(0) }) }

  def requests = client.api_requests.select { it[:operation_name] == :get_parameter }.map { it[:params] }

  it 'fetches the decrypted value and reuses it for cache_seconds' do
    client.stub_responses(:get_parameter, {parameter: {value: 'one'}}, {parameter: {value: 'two'}})
    expect(source.value).to eq('one')
    clock[0] += 59
    expect(source.value).to eq('one')
    clock[0] += 1
    expect(source.value).to eq('two')
    expect(requests).to eq([{name: '/glazed/password', with_decryption: true}] * 2)
  end

  it 'raises Unavailable for a missing parameter' do
    client.stub_responses(:get_parameter, 'ParameterNotFound')
    expect { source.value }.to raise_error(Glazed::Secret::Unavailable, %r{SSM parameter /glazed/password})
  end

  it 'lets other errors propagate' do
    client.stub_responses(:get_parameter, 'AccessDeniedException')
    expect { source.value }.to raise_error(Aws::SSM::Errors::AccessDeniedException)
  end

  it 'serves an ssm secret reference, fetching once per resolver' do
    client.stub_responses(:get_parameter, {parameter: {value: 'pw'}})
    allow(Aws::SSM::Client).to receive(:new).with(region: 'ap-northeast-1').and_return(client)
    ref = Glazed::Proto::V1::SecretRef.new(ssm: {name: '/glazed/password', region: 'ap-northeast-1'})
    resolver = Glazed::SecretsResolver.new
    expect([resolver.secret(ref).value, resolver.secret(ref.dup).value]).to eq(%w[pw pw])
    expect(requests.size).to eq(1)
    Glazed::SecretsResolver.new.value(ref)
    expect(requests.size).to eq(2)
    expect(resolver.secret(ref).inspect).to eq('#<Glazed::Secret ssm>')
  end
end
