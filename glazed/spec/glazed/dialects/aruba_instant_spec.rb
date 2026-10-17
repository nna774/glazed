# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/aruba_instant'

RSpec.describe Glazed::Dialects::ArubaInstant do
  it_behaves_like 'a dialect simulation', 'aruba_instant/iap515_8.10.0.6', transport: 'ssh'
  it_behaves_like 'a dialect simulation', 'aruba_instant/iap303_secrets', transport: 'ssh'

  describe 'login' do
    let(:responses) do
      {
        'enable' => 'Password: ',
        'en4ble' => "\r\nap1# ",
        'show version' => 'ap1# ',
        'show activate status' => 'ap1# ',
        'show aps' => 'ap1# ',
        'show running-config no-encrypt' => "version 8\r\nap1# ",
        'exit' => '',
      }
    end
    let(:device) { FakeTransport.device(greeting: 'ap1> ', responses:) }

    before { stub_const('Glazed::Transports::Ssh', device) }

    def collect(**node) = Glazed::Collector.new(node: Glazed::Proto::V1::Node.new(name: 'ap1', dialect: 'aruba_instant', **node), timeout: 1).call

    it 'logs in without enable mode by default' do
      collect
      expect(device.instances.first.written).to eq(["show version\n", "show activate status\n", "show aps\n", "show running-config no-encrypt\n", "exit\n"])
    end

    it 'enters enable mode with the enable secret and leaves it twice' do
      collect(secrets: {'enable' => {value: 'en4ble'}})
      written = device.instances.first.written
      expect(written.first(3)).to eq(["enable\n", "en4ble\n", "show version\n"])
      expect(written.last(2)).to eq(%W[exit\n exit\n])
    end

    it 'runs enable without a password when the param asks for it' do
      responses['enable'] = 'ap1# '
      collect(params: {'enable' => 'true'})
      expect(device.instances.first.written.first).to eq("enable\n")
    end
  end
end
