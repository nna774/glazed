# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'socket'
require 'glazed/transports/telnet'

RSpec.describe Glazed::Transports::Telnet do
  let(:server) { TCPServer.new('127.0.0.1', 0) }
  let(:transport) do
    described_class.new(host: '127.0.0.1', port: server.addr[1], username: 'admin', password: nil, connect_timeout: 2)
  end

  after do
    transport.close
    server.close
  end

  def read_until(pattern)
    data = +''
    data << (transport.read(timeout: 1) || break) until data.match?(pattern)
    data
  end

  it 'strips negotiation, sends CRLF, and reports end of stream' do
    received = Queue.new
    thread = Thread.new do
      client = server.accept
      client.write("\xFF\xFB\x01login: ".b) # IAC WILL ECHO
      received << client.read(3)
      received << client.gets("\r\n")
      client.close
    end
    transport.open
    expect(read_until(/login: /)).to eq('login: ')
    transport.write("admin\n")
    expect(received.pop).to eq("\xFF\xFD\x01".b) # IAC DO ECHO
    expect(received.pop).to eq("admin\r\n")
    thread.join
    expect(transport.read(timeout: 1)).to be_nil
  end

  it 'returns an empty string when nothing arrives in time' do
    thread = Thread.new { server.accept }
    transport.open
    expect(transport.read(timeout: 0.05)).to eq('')
    thread.join
  end
end
