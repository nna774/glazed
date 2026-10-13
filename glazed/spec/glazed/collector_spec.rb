# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/collector'

RSpec.describe Glazed::Collector do
  let(:dialect) do
    Class.new(Glazed::Dialects::Base) do
      prompt(/^rt1[#>]\s?$/)
      filter_output { it.delete("\r") }
      runbook(:get) { it.command('show running-config') }
      communication(:telnet) do |config|
        config.username_prompt = /^Username:\s/
        config.password_prompt = /^Password:\s/
      end
      communication(:fake, :telnet) do |config|
        config.post_login { |run| run.cli.command('terminal length 0') }
        config.pre_logout { |run| run.cli.write("exit\n") }
      end
      communication(:exec_only) { it.exec = true }
    end
  end
  let(:responses) do
    {
      'admin' => 'Password: ',
      's3cret' => "\r\nrt1#",
      'terminal length 0' => "rt1#",
      'show running-config' => "hostname rt1\r\nrt1#",
      'exit' => '',
    }
  end
  let(:node) do
    Glazed::Proto::V1::Node.new(name: 'rt1', dialect: 'test_os', transport:, username: 'admin', password: {value: 's3cret'})
  end

  let(:transport) { 'telnet' }

  before { stub_const('Glazed::Dialects::TestOs', dialect) }

  context 'over a transport with login prompts' do
    let(:device) { FakeTransport.device(greeting: "banner\r\nUsername: ", responses:) }

    before { stub_const('Glazed::Transports::Telnet', device) }

    it 'logs in, runs hooks and the runbook, and logs out' do
      expect(described_class.new(node:, timeout: 1).call).to eq("hostname rt1\n")
      expect(device.instances.first.written).to eq(["admin\n", "s3cret\n", "terminal length 0\n", "show running-config\n", "exit\n"])
      expect(device.instances.first).to be_closed
    end
  end

  context 'over a transport that authenticates itself' do
    let(:transport) { 'fake' }
    let(:device) { FakeTransport.device(greeting: "rt1#", responses:) }

    before { stub_const('Glazed::Transports::Fake', device) }

    it 'waits for the prompt without answering login prompts' do
      expect(described_class.new(node:, timeout: 1).call).to eq("hostname rt1\n")
      expect(device.instances.first.written.first).to eq("terminal length 0\n")
    end

    it 'closes the transport when the runbook fails' do
      responses.delete('show running-config')
      expect { described_class.new(node:, timeout: 1).call }.to raise_error(FakeTransport::UnexpectedInput)
      expect(device.instances.first).to be_closed
    end
  end

  context 'with exec-only communication' do
    let(:transport) { 'exec_only' }
    let(:device) { FakeTransport.device(exec_responses: {'show running-config' => "hostname rt1\r\n"}) }

    before { stub_const('Glazed::Transports::ExecOnly', device) }

    it 'never touches the shell' do
      expect(described_class.new(node:, timeout: 1).call).to eq("hostname rt1\n")
      expect(device.instances.first.written).to be_empty
    end
  end

  it 'connects to the node name when no host is set' do
    allow(Glazed::Transports::Telnet).to receive(:new).and_call_original
    described_class.new(node:)
    expect(Glazed::Transports::Telnet).to have_received(:new).with(host: 'rt1', port: nil, username: 'admin', password: be_a(Glazed::Secret))
  end
end
