# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/collector'
require 'glazed/transports/telnet'

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
      communication(:wide) { it.pty_options[:chars_wide] = 200 }
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

    it 'reports connecting and each wait for the device' do
      messages = []
      described_class.new(node:, timeout: 1, progress: ->(message) { messages << message }).call
      expect(messages).to eq([
        'connecting to fake over telnet',
        'waiting for /^Username:\s/ or /^Password:\s/ or prompt',
        'waiting for /^Password:\s/ or prompt',
        'waiting for prompt',
        'waiting for prompt after "terminal length 0"',
        'waiting for prompt after "show running-config"',
      ])
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

  context 'with PTY options' do
    let(:transport) { 'wide' }
    let(:device) { FakeTransport.device(greeting: 'rt1#', responses:) }

    before { stub_const('Glazed::Transports::Wide', device) }

    it 'hands them to the transport' do
      described_class.new(node:, timeout: 1).call
      expect(device.instances.last.pty_options).to eq(chars_wide: 200)
    end
  end

  context 'with a device not using UTF-8' do
    let(:transport) { 'fake' }
    let(:device) do
      FakeTransport.device(greeting: 'rt1#', responses: {
        'terminal length 0' => 'rt1#',
        'show running-config' => "hostname ルータ1\r\nrt1#".encode('Shift_JIS').b,
        'exit' => '',
      })
    end

    before { stub_const('Glazed::Transports::Fake', device) }

    it 'refuses output that is not UTF-8' do
      expect { described_class.new(node:, timeout: 1).call }
        .to raise_error(Glazed::InvalidEncoding, /"show running-config" is not valid UTF-8/)
    end

    it 'accepts output the dialect converts to UTF-8' do
      dialect.filter_output { it.dup.force_encoding(Encoding::Shift_JIS).encode(Encoding::UTF_8) }
      output = described_class.new(node:, timeout: 1).call
      expect(output).to eq("hostname ルータ1\n")
      expect(output.encoding).to eq(Encoding::UTF_8)
    end
  end

  it 'connects to the node name when no host is set' do
    allow(Glazed::Transports::Telnet).to receive(:new).and_call_original
    described_class.new(node:)
    expect(Glazed::Transports::Telnet).to have_received(:new).with(host: 'rt1', port: nil, username: 'admin', password: be_a(Glazed::Secret), transport_options: nil, secrets: be_a(Glazed::SecretsResolver))
  end

  it 'hands the transport options of the node to the transport' do
    node.transport_options = Glazed::Proto::V1::TransportOptions.new(ssh: {compression: true})
    allow(Glazed::Transports::Telnet).to receive(:new).and_call_original
    described_class.new(node:)
    expect(Glazed::Transports::Telnet).to have_received(:new).with(hash_including(transport_options: node.transport_options))
  end
end
