# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/aws/execution_liveness'

RSpec.describe Glazed::Aws::ExecutionLiveness do
  let(:arn) { 'arn:aws:states:ap-northeast-1:123456789012:execution:glazed:manual-1' }
  let(:client) { Aws::States::Client.new(stub_responses: true) }
  let(:liveness) { described_class.new(client:) }

  def describing(status)
    client.stub_responses(:describe_execution, {execution_arn: arn, state_machine_arn: 'arn', status:, start_date: Time.now})
  end

  it 'holds a running or pending redrive execution alive' do
    describing('RUNNING')
    expect(liveness.call(arn)).to be(true)
    describing('PENDING_REDRIVE')
    expect(liveness.call(arn)).to be(true)
    expect(client.api_requests.map { it[:params][:execution_arn] }).to eq([arn, arn])
  end

  it 'reports an ended execution' do
    describing('FAILED')
    expect(liveness.call(arn)).to be(false)
    describing('ABORTED')
    expect(liveness.call(arn)).to be(false)
  end

  it 'reports an execution Step Functions no longer knows' do
    client.stub_responses(:describe_execution, 'ExecutionDoesNotExist')
    expect(liveness.call(arn)).to be(false)
  end

  it 'presumes other tokens alive without a request' do
    expect(liveness.call('manual-1')).to be(true)
    expect(liveness.call('host:123:abcd')).to be(true)
    expect(client.api_requests).to be_empty
  end

  it 'propagates other errors' do
    client.stub_responses(:describe_execution, 'AccessDeniedException')
    expect { liveness.call(arn) }.to raise_error(Aws::States::Errors::ServiceError) { expect(it.code).to eq('AccessDeniedException') }
  end
end
