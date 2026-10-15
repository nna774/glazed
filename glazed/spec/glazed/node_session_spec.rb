# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/node_session'

RSpec.describe Glazed::NodeSession do
  let(:dialect) do
    Class.new(Glazed::Dialects::Base) do
      prompt(/^rt1[#>]\s?$/)
      communication(:fake) do |config|
        config.post_login { |run| run.cli.command('terminal length 0') }
        config.pre_logout { |run| run.cli.write("exit\n") }
      end
      communication(:exec_only) { it.exec = true }
    end
  end
  let(:responses) { {'terminal length 0' => 'rt1#', 'show version' => "v1\r\nrt1#", 'exit' => ''} }
  let(:node) { Glazed::Proto::V1::Node.new(name: 'rt1', dialect: 'test_os', transport:) }
  let(:transport) { 'fake' }

  before { stub_const('Glazed::Dialects::TestOs', dialect) }

  context 'over a shell' do
    let(:device) { FakeTransport.device(greeting: 'rt1#', responses:) }

    before { stub_const('Glazed::Transports::Fake', device) }

    it 'runs the post-login hooks on open and the pre-logout hooks on logout' do
      session = described_class.new(node:, timeout: 1)
      session.open
      expect(session.cli.command('show version').output).to eq("v1\r\n")
      session.logout
      session.close
      expect(device.instances.first.written).to eq(["terminal length 0\n", "show version\n", "exit\n"])
      expect(device.instances.first).to be_closed
    end

    it 'closes the transport when a post-login hook fails' do
      responses.delete('terminal length 0')
      expect { described_class.new(node:, timeout: 1).open }.to raise_error(FakeTransport::UnexpectedInput)
      expect(device.instances.first).to be_closed
    end

    it 'tries extra interactions after the dialect' do
      responses['show version'] = "--Page--\r\nrt1#"
      answered = Glazed::Dialect::Interaction.new(pattern: /--Page--/, responder: ->(_cli, _buffer, match) { Glazed::Dialect::Actions::Replace.new(content: match.pre_match + match.post_match) })
      session = described_class.new(node:, timeout: 1, interactions: [answered])
      session.open
      expect(session.cli.command('show version').output).to eq("\r\n")
    end
  end

  context 'with exec-only communication' do
    let(:transport) { 'exec_only' }
    let(:device) { FakeTransport.device(greeting: 'rt1#', responses:, exec_responses: {'show version' => "v1\r\n"}) }

    before { stub_const('Glazed::Transports::ExecOnly', device) }

    it 'uses the shell when exec is turned off' do
      session = described_class.new(node:, timeout: 1, exec: false)
      session.open
      expect(session.cli.command('show version').output).to eq("v1\r\n")
      expect(device.instances.first.written).to eq(["show version\n"])
    end
  end
end
