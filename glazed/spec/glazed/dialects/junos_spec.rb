# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/junos'

RSpec.describe Glazed::Dialects::Junos do
  it_behaves_like 'a dialect simulation', 'junos/srx300_22.4', transport: 'ssh', exec: true

  describe 'params' do
    let(:device) do
      FakeTransport.device(exec_responses: {
        'show version' => "Model: srx300\n",
        'show chassis hardware' => '',
        'show system license' => "License usage:\n  Feature name  used\n  idp-sig  1\n\nLicenses installed: none\n",
        'show system license keys' => '',
        'show configuration | display omit' => "version 22.4;\n",
      })
    end

    before { stub_const('Glazed::Transports::Ssh', device) }

    def collect(**node) = Glazed::Collector.new(node: Glazed::Proto::V1::Node.new(name: 'rt1', dialect: 'junos', **node), timeout: 1).call

    it 'keeps the license usage table by default' do
      expect(collect).to include('# License usage:')
    end

    it 'omits the license usage table when the param asks for it' do
      output = collect(params: {'junos_license_usage' => 'false'})
      expect(output).not_to include('License usage')
      expect(output).to include('# Licenses installed: none')
    end
  end
end
