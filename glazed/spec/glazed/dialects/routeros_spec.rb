# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/routeros'

RSpec.describe Glazed::Dialects::Routeros do
  it_behaves_like 'a dialect simulation', 'routeros/CHR_7.10.1', transport: 'ssh', exec: true
  it_behaves_like 'a dialect simulation', 'routeros/CHR_7.16', transport: 'ssh', exec: true
  it_behaves_like 'a dialect simulation', 'routeros/L009UiGS_7.15.2', transport: 'ssh', exec: true

  context 'with a RouterOS 6 shell over Telnet' do
    it_behaves_like 'a dialect simulation', 'routeros/v6_telnet', transport: 'telnet'

    it 'logs in with the Login and Password prompts and quits' do
      device = Simulation.load('routeros/v6_telnet').shell_device
      stub_const('Glazed::Transports::Telnet', device)
      node = Glazed::Proto::V1::Node.new(name: 'rt1', dialect: 'routeros', transport: 'telnet', username: 'admin', password: {value: 'pw'})
      Glazed::Collector.new(node:, timeout: 1).call
      written = device.instances.first.written
      expect(written.first(2)).to eq(["admin\n", "pw\n"])
      expect(written.last).to eq("quit\n")
    end
  end

  describe 'export command' do
    let(:responses) do
      {
        '/system resource print' => "version: 7.1\n",
        '/system package update print' => "installed-version: #{version}\n",
        '/system history print without-paging' => '',
      }
    end
    let(:version) { '7.16' }
    let(:device) { FakeTransport.device(exec_responses: responses) }
    let(:params) { {} }

    before { stub_const('Glazed::Transports::Ssh', device) }

    def collect = Glazed::Collector.new(node: Glazed::Proto::V1::Node.new(name: 'rt1', dialect: 'routeros', params:), timeout: 1).call

    it 'shows sensitive values from RouterOS 7' do
      responses['/export show-sensitive'] = "/system identity\nset name=a\n"
      expect(collect).to end_with("set name=a\n")
    end

    context 'with RouterOS 6' do
      let(:version) { '6.49.10' }

      it 'runs a plain export' do
        responses['/export'] = "/system identity\nset name=a\n"
        expect(collect).to end_with("set name=a\n")
      end
    end

    context 'when the version is unknown' do
      let(:responses) do
        {'/system resource print' => '', '/system package update print' => '', '/system history print without-paging' => '', '/export' => "set name=a\n"}
      end

      it 'runs a plain export' do
        expect(collect).to eq("set name=a\n")
      end
    end

    context 'with param routeros_hide_sensitive' do
      let(:params) { {'routeros_hide_sensitive' => 'true'} }

      it 'hides sensitive values on every version' do
        responses['/export hide-sensitive'] = "set name=a\n"
        expect(collect).to end_with("set name=a\n")
      end
    end
  end
end
