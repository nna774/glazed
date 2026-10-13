# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/ios'

RSpec.describe Glazed::Dialects::Ios do
  it_behaves_like 'a dialect simulation', 'ios/asr920_16.8.1b', transport: 'ssh'
  it_behaves_like 'a dialect simulation', 'ios/C9200L-24P-4G_17.09.04a', transport: 'ssh'
  it_behaves_like 'a dialect simulation', 'ios/C9800-L-F-K9_17.06.05', transport: 'ssh'

  describe 'login' do
    let(:responses) do
      {
        'enable' => "Password: ",
        'en4ble' => "\r\nrt1#",
        'terminal length 0' => "rt1#",
        'terminal width 0' => "rt1#",
        'show version' => "rt1#",
        'show vtp status' => "rt1#",
        'show inventory' => "rt1#",
        'show running-config' => "hostname rt1\r\nrt1#",
        'show running-config view full' => "hostname rt1 full\r\nrt1#",
        'exit' => '',
      }
    end
    let(:device) { FakeTransport.device(greeting: 'rt1>', responses:) }

    before { stub_const('Glazed::Transports::Ssh', device) }

    def collect(**node) = Glazed::Collector.new(node: Glazed::Proto::V1::Node.new(name: 'rt1', dialect: 'ios', **node), timeout: 1).call

    it 'enters enable mode with the enable secret' do
      collect(secrets: {'enable' => {value: 'en4ble'}})
      expect(device.instances.first.written.first(3)).to eq(["enable\n", "en4ble\n", "terminal length 0\n"])
    end

    it 'runs enable without a password when the param asks for it' do
      responses['enable'] = 'rt1#'
      collect(params: {'enable' => 'true'})
      expect(device.instances.first.written.first).to eq("enable\n")
    end

    it 'collects the full view for RBAC users' do
      expect(collect(params: {'ios_rbac' => 'true'})).to end_with("hostname rt1 full\n")
    end
  end
end
