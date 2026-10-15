# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/cli_session'

RSpec.describe Glazed::CliSession do
  let(:prompt) { /^rt1#\s?$/ }
  let(:session_options) { {} }
  let(:session) { described_class.new(transport:, prompt:, timeout: 1, **session_options) }

  before { transport.open }

  context 'with a plain device' do
    let(:transport) do
      FakeTransport.new(greeting: "rt1#", responses: {'show version' => "Version 1\r\nUptime 2\r\nrt1#", 'enable' => 'Password: '})
    end

    it 'returns output without the echo and the prompt' do
      expect(session.command('show version').output).to eq("Version 1\r\nUptime 2\r\n")
    end

    it 'writes the command with a newline' do
      session.command('show version')
      expect(transport.written).to eq(["show version\n"])
    end

    it 'consumes text up to an expected match' do
      session.write("enable\n")
      expect(session.expect(/Password:\s/)[0]).to eq('Password: ')
      expect(session.buffer).to eq('')
    end

    it 'raises TimeoutError when nothing matches' do
      session.expect(prompt)
      expect { session.expect(/never/, timeout: 0.05) }.to raise_error(Glazed::TimeoutError, /never/)
    end

    it 'keeps waiting while output arrives within the timeout' do
      session.expect(prompt)
      chunks = ['l1', 'l2', 'l3', 'l4', "\r\nrt1#"]
      transport.define_singleton_method(:read) do |timeout:|
        sleep([timeout, 0.03].min)
        chunks.shift.to_s
      end
      expect(session.expect(prompt, timeout: 0.05)[0]).to eq('rt1#')
    end

    it 'raises ConnectionClosed at end of stream' do
      session.expect(prompt)
      transport.close
      expect { session.expect(/never/) }.to raise_error(Glazed::ConnectionClosed)
    end
  end

  context 'with a pager' do
    let(:transport) do
      FakeTransport.new(responses: {'show run' => "l1\nl2\nl3\nl4\nl5\nrt1#"}, pager: 2, more: '--More--')
    end
    let(:pager) do
      Glazed::Dialect::Interaction.new(
        pattern: /--More--/,
        responder: lambda do |cli, buffer, match|
          cli.write(' ')
          Glazed::Dialect::Actions::Replace.new(content: buffer.sub(match[0], ''))
        end,
      )
    end
    let(:session_options) { {interactions: [pager]} }

    it 'pages through the output' do
      expect(session.command('show run').output).to eq("l1\nl2\nl3\nl4\nl5\n")
      expect(transport.written).to eq(["show run\n", ' ', ' '])
    end
  end

  context 'with data filters' do
    let(:transport) { FakeTransport.new(responses: {'show' => "a\e[7m\e[mb\r\nrt1#"}) }
    let(:session_options) { {data_filters: [->(fragment) { fragment.gsub("\e[7m\e[m", '').delete("\r") }]} }

    it 'filters received data' do
      expect(session.command('show').output).to eq("ab\n")
    end
  end

  context 'with UTF-8 output arriving a byte at a time' do
    let(:transport) { FakeTransport.new(responses: {'show' => "ルータ1\r\nrt1#"}) }

    before do
      pending_bytes = String.new(encoding: Encoding::BINARY)
      transport.define_singleton_method(:read) do |timeout:|
        pending_bytes << super(timeout:).to_s.b
        pending_bytes.slice!(0, 1)
      end
    end

    it 'matches the prompt across split characters' do
      expect(session.command('show').output.dup.force_encoding(Encoding::UTF_8)).to eq("ルータ1\r\n")
    end
  end

  context 'with exec' do
    let(:transport) { FakeTransport.new(exec_responses: {'show version' => "Model: mx960\r\n"}) }
    let(:session_options) { {exec: true, data_filters: [->(fragment) { fragment.delete("\r") }]} }

    it 'runs the command through the transport exec' do
      expect(session.command('show version').output).to eq("Model: mx960\n")
      expect(transport.written).to be_empty
    end
  end
end
