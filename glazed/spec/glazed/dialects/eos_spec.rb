# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/eos'

RSpec.describe Glazed::Dialects::Eos do
  it_behaves_like 'a dialect simulation', 'eos/dcs7050', transport: 'ssh'

  describe 'login' do
    let(:responses) do
      {
        'enable' => 'Password: ',
        'en4ble' => "\r\nswitch1#",
        'terminal length 0' => 'switch1#',
        'show inventory | no-more' => 'switch1#',
        'show running-config | no-more | exclude ! Time:' => "hostname switch1\r\nswitch1#",
        'exit' => '',
      }
    end
    let(:device) { FakeTransport.device(greeting: 'switch1>', responses:) }

    before { stub_const('Glazed::Transports::Ssh', device) }

    def collect(**node) = Glazed::Collector.new(node: Glazed::Proto::V1::Node.new(name: 'sw1', dialect: 'eos', **node), timeout: 1).call

    it 'enters enable mode with the enable secret' do
      collect(secrets: {'enable' => {value: 'en4ble'}})
      expect(device.instances.first.written.first(3)).to eq(["enable\n", "en4ble\n", "terminal length 0\n"])
    end

    it 'runs enable without a password when the param asks for it' do
      responses['enable'] = 'switch1#'
      collect(params: {'enable' => 'true'})
      expect(device.instances.first.written.first(2)).to eq(["enable\n", "terminal length 0\n"])
    end

    it 'skips enable by default' do
      collect
      expect(device.instances.first.written.first).to eq("terminal length 0\n")
    end
  end
end
