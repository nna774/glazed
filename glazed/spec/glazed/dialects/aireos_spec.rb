# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/aireos'

RSpec.describe Glazed::Dialects::Aireos do
  it_behaves_like 'a dialect simulation', 'aireos/ct2504', transport: 'ssh'

  it 'logs in inside the SSH session and declines saving on logout' do
    device = Simulation.load('aireos/ct2504').shell_device
    stub_const('Glazed::Transports::Ssh', device)
    node = Glazed::Proto::V1::Node.new(name: 'wlc1', dialect: 'aireos', username: 'admin', password: {value: 'pw'})
    Glazed::Collector.new(node:, timeout: 1).call
    written = device.instances.first.written
    expect(written.first(3)).to eq(["admin\n", "pw\n", "config paging disable\n"])
    expect(written.last(2)).to eq(["logout\n", 'n'])
  end
end
