# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'net/telnet'
require 'glazed'
require 'glazed/must'
require 'glazed/transports/base'

module Glazed
  module Transports
    # Telnet transport. Login prompts are left to the session.
    class Telnet < Base
      # Standard Telnet port.
      DEFAULT_PORT = 23 #: Integer
      # Bytes read from the socket at once.
      READ_SIZE = 65_536 #: Integer

      # @param host [String] hostname or address
      # @param port [Integer, nil] port, or nil for 23
      # @param username [String] login user name
      # @param password [Secret, nil] login password
      # @param connect_timeout [Numeric] seconds to wait for a connection
      # @param transport_options [Proto::V1::TransportOptions, nil] per-transport connection options
      # @param secrets [SecretsResolver] reads secrets in the transport options
      #: (host: String, port: Integer?, username: String, password: Secret?, ?connect_timeout: Numeric, ?transport_options: Proto::V1::TransportOptions?, ?secrets: SecretsResolver) -> void
      def initialize(host:, port:, username:, password:, connect_timeout: DEFAULT_CONNECT_TIMEOUT, transport_options: nil, secrets: SecretsResolver.new)
        super
        @telnet = nil #: Net::Telnet?
        @rest = +'' #: String
      end

      # Connects to the device.
      #
      # @return [void]
      # @raise [Net::OpenTimeout] when the connection is not established in time
      #: () -> void
      def open
        @telnet = Net::Telnet.new(
          'Host' => host,
          'Port' => port || DEFAULT_PORT,
          'Timeout' => connect_timeout,
          'Telnetmode' => true,
          'Binmode' => false,
        )
      end

      # Sends data, translating newlines as negotiated.
      #
      # @param data [String] bytes to send
      # @return [void]
      #: (String data) -> void
      def write(data)
        telnet.print(data)
      end

      # Receives data with Telnet commands processed.
      #
      # @param timeout [Numeric] seconds to wait for data
      # @return [String, nil] received data, empty when none arrived in time, nil at end of stream
      #: (timeout: Numeric) -> String?
      def read(timeout:)
        sock = telnet.sock
        return +'' unless sock.wait_readable(timeout)

        data = @rest + sock.readpartial(READ_SIZE)
        # Same split as Net::Telnet#waitfor, which keeps an unfinished
        # command or CR for the next read.
        cut = if (sb = data.rindex(/#{Net::Telnet::IAC}#{Net::Telnet::SB}/no)) &&
                 sb > (data.rindex(/#{Net::Telnet::IAC}#{Net::Telnet::SE}/no) || 0)
          sb
        else
          data.rindex(/#{Net::Telnet::IAC}[^#{Net::Telnet::IAC}#{Net::Telnet::AO}#{Net::Telnet::AYT}#{Net::Telnet::DM}#{Net::Telnet::IP}#{Net::Telnet::NOP}]?\z/no) ||
            data.rindex(/\r\z/no)
              end
        @rest = cut ? (data[cut..] || +'') : +''
        telnet.preprocess(cut ? (data[0...cut] || +'') : data)
      rescue EOFError
        nil
      end

      # Closes the connection.
      #
      # @return [void]
      #: () -> void
      def close
        telnet = @telnet
        @telnet = nil
        telnet&.close
      rescue IOError, SystemCallError
        # The device may already have dropped the connection after logout.
        nil
      end

      # @return [Net::Telnet] the open connection
      # @raise [Must::Violation] before {#open}
      #: () -> Net::Telnet
      private def telnet = Must.because(@telnet) { 'open is called before using the transport' }
    end
  end
end
