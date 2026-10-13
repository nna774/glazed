# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'socket'

# Telnet server playing a Simulation behind a username and password login.
# Each connection is served on its own thread until the client sends "exit".
class TelnetDevice
  def initialize(simulation, username:, password:)
    @simulation = simulation
    @username = username
    @password = password
    @server = TCPServer.new('127.0.0.1', 0)
    @thread = Thread.new { serve }
  end

  def port = @server.addr[1]

  def close
    @thread.kill
    @server.close
  end

  private def serve
    loop do
      client = @server.accept
      Thread.new(client) { session(it) }
    end
  rescue IOError
    nil
  end

  private def session(client)
    prompt = @simulation.init_prompt.lines.last
    client.write("Username: ")
    return unless read_line(client) == @username

    client.write("#{@username}\r\nPassword: ")
    return unless read_line(client) == @password

    client.write("\r\n#{prompt}")
    while (line = read_line(client)) && line != 'exit'
      client.write(@simulation.commands.fetch(line) { "#{line}\r\n% Invalid input\r\n#{prompt}" })
    end
  ensure
    client.close
  end

  private def read_line(client)
    line = client.gets("\n")&.delete("\r\0")&.chomp
    line&.sub(/\A(?:\xFF[\xFB-\xFE].)+/n, '')
  end
end
