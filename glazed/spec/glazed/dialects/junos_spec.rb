# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/junos'

RSpec.describe Glazed::Dialects::Junos do
  it_behaves_like 'a dialect simulation', 'junos/srx300_22.4', transport: 'ssh', exec: true

  describe 'params' do
    let(:exec_responses) do
      {
        'show version' => "Model: srx300\n",
        'show chassis hardware' => '',
        'show system license' => "License usage:\n  Feature name  used\n  idp-sig  1\n\nLicenses installed: none\n",
        'show system license keys' => '',
        'show configuration | display omit' => "version 22.4;\n",
      }
    end
    let(:device) { FakeTransport.device(exec_responses:) }

    before { stub_const('Glazed::Transports::Ssh', device) }

    def collect(**node) = Glazed::Collector.new(node: Glazed::Proto::V1::Node.new(name: 'rt1', dialect: 'junos', **node), timeout: 1).call

    it 'collects licenses by default' do
      expect(collect).to include('# License usage:')
    end

    it 'skips the license commands when the param asks for it' do
      exec_responses.delete_if { |command, _| command.start_with?('show system license') }
      expect(collect(params: {'junos_license' => 'false'})).not_to include('License')
    end
  end
end
