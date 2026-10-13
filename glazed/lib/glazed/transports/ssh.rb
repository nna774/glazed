# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'net/ssh'
require 'glazed'
require 'glazed/must'
require 'glazed/transports/base'

module Glazed
  module Transports
    # SSH transport with an interactive PTY shell and exec channels.
    class Ssh < Base
      # Standard SSH port.
      DEFAULT_PORT = 22 #: Integer
      # PTY requested for the shell, wide enough to avoid line wrapping.
      DEFAULT_PTY_OPTIONS = {term: 'vt100', chars_wide: 512}.freeze #: Hash[Symbol, untyped]
      # Seconds {#close} waits for the device to acknowledge closing channels.
      CLOSE_TIMEOUT = 5 #: Integer

      # @param host [String] hostname or address
      # @param port [Integer, nil] port, or nil for 22
      # @param username [String] login user name
      # @param password [Secret, nil] login password
      # @param connect_timeout [Numeric] seconds to wait for a connection
      #: (host: String, port: Integer?, username: String, password: Secret?, ?connect_timeout: Numeric) -> void
      def initialize(host:, port:, username:, password:, connect_timeout: DEFAULT_CONNECT_TIMEOUT)
        super
        @session = nil #: Net::SSH::Connection::Session?
        @shell = nil #: Net::SSH::Connection::Channel?
        @inbox = +'' #: String
        @eof = false #: bool
      end

      # Connects and authenticates.
      #
      # @return [void]
      # @raise [Net::SSH::Exception] when the connection or authentication fails
      #: () -> void
      def open
        @session = Net::SSH.start(
          host, username,
          port: port || DEFAULT_PORT,
          password: password&.value,
          timeout: connect_timeout,
          non_interactive: true,
        )
      end

      # Sends data to the shell, opening it on first use.
      #
      # @param data [String] bytes to send
      # @return [void]
      #: (String data) -> void
      def write(data)
        shell.send_data(data)
        session.process(0)
      end

      # Receives data from the shell, opening it on first use.
      #
      # @param timeout [Numeric] seconds to wait for data
      # @return [String, nil] received data, empty when none arrived in time, nil once the shell closed
      #: (timeout: Numeric) -> String?
      def read(timeout:)
        shell
        deadline = now + timeout.to_f
        while @inbox.empty? && !@eof && (remaining = deadline - now).positive?
          session.process([remaining, 0.1].min)
        end
        return nil if @inbox.empty? && @eof

        data = @inbox
        @inbox = +''
        data
      end

      # @return [Boolean] always true; SSH authenticates during {#open}
      #: () -> bool
      def authenticates? = true

      # @return [Boolean] always true
      #: () -> bool
      def exec? = true

      # Runs a command on its own exec channel.
      #
      # @param command [String] command line
      # @param timeout [Numeric] seconds to wait for the channel to close
      # @return [String] combined stdout and stderr
      # @raise [Glazed::Error] when the device refuses the exec request
      # @raise [Glazed::TimeoutError] when the command does not finish in time
      #: (String command, timeout: Numeric) -> String
      def exec(command, timeout:)
        output = +''
        closed = false #: bool
        session.open_channel do |channel|
          channel.exec(command) do |_, success|
            raise Glazed::Error, "#{host}: exec request refused for #{command.inspect}" unless success
          end
          channel.on_data { |_, data| output << data }
          channel.on_extended_data { |_, _, data| output << data }
          channel.on_close { closed = true }
        end
        deadline = now + timeout.to_f
        session.loop(0.1) do
          raise Glazed::TimeoutError, "#{host}: #{command.inspect} did not finish in #{timeout}s" if !closed && now > deadline

          !closed
        end
        output
      end

      # Closes the shell and the session. The connection is dropped when the
      # device does not acknowledge closing the channels within {CLOSE_TIMEOUT}.
      #
      # @return [void]
      #: () -> void
      def close
        session = @session
        return unless session

        @session = nil
        @shell = nil
        return if session.closed?

        session.channels.each_value(&:close)
        deadline = now + CLOSE_TIMEOUT
        session.loop(0.1) { session.channels.any? && now < deadline }
        session.channels.empty? ? session.close : session.shutdown!
      rescue IOError, SystemCallError, Net::SSH::Disconnect
        # The device may already have dropped the connection after logout.
        nil
      end

      # @return [Net::SSH::Connection::Session] the open session
      # @raise [Must::Violation] before {#open}
      #: () -> Net::SSH::Connection::Session
      private def session = Must.because(@session) { 'open is called before using the transport' }

      # @return [Net::SSH::Connection::Channel] the shell channel, opened on first use
      #: () -> Net::SSH::Connection::Channel
      private def shell
        @shell ||= open_shell
      end

      # @return [Net::SSH::Connection::Channel] a channel running a PTY shell
      # @raise [Glazed::Error] when the device refuses the PTY or shell
      # @raise [Glazed::TimeoutError] when the device does not answer within the connect timeout
      #: () -> Net::SSH::Connection::Channel
      private def open_shell
        ready = false #: bool
        channel = session.open_channel do |ch|
          ch.request_pty(DEFAULT_PTY_OPTIONS.merge(pty_options)) do |_, success|
            raise Glazed::Error, "#{host}: PTY request refused" unless success
          end
          ch.send_channel_request('shell') do |_, success|
            raise Glazed::Error, "#{host}: shell request refused" unless success

            ready = true
          end
          ch.on_data { |_, data| @inbox << data }
          ch.on_extended_data { |_, _, data| @inbox << data }
          ch.on_close { @eof = true }
        end
        deadline = now + connect_timeout.to_f
        session.loop(0.1) do
          raise Glazed::TimeoutError, "#{host}: shell did not open in #{connect_timeout}s" if !ready && now > deadline

          !ready && !@eof
        end
        channel
      end
    end
  end
end
