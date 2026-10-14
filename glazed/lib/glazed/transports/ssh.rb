# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'net/ssh'
require 'net/ssh/proxy/command'
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
      # net-ssh verify_host_key values by {Proto::V1::SshOptions::HostKeyVerification}.
      VERIFY_HOST_KEY = {
        HOST_KEY_VERIFICATION_NEVER: :never,
        HOST_KEY_VERIFICATION_ACCEPT_NEW: :accept_new,
        HOST_KEY_VERIFICATION_ACCEPT_NEW_OR_LOCAL_TUNNEL: :accept_new_or_local_tunnel,
        HOST_KEY_VERIFICATION_ALWAYS: :always,
      }.freeze #: Hash[Symbol, Symbol]
      # Repeated string fields of {Proto::V1::SshOptions} that are net-ssh options of the same name.
      LIST_OPTIONS = %i[auth_methods user_known_hosts_file global_known_hosts_file host_key kex encryption hmac].freeze #: Array[Symbol]

      # @param host [String] hostname or address
      # @param port [Integer, nil] port, or nil for 22
      # @param username [String] login user name
      # @param password [Secret, nil] login password
      # @param connect_timeout [Numeric] seconds to wait for a connection
      # @param transport_options [Proto::V1::TransportOptions, nil] per-transport connection options
      # @param secrets [SecretsResolver] reads secrets in the transport options
      #: (host: String, port: Integer?, username: String, password: Secret?, ?connect_timeout: Numeric, ?transport_options: Proto::V1::TransportOptions?, ?secrets: SecretsResolver) -> void
      def initialize(host:, port:, username:, password:, connect_timeout: DEFAULT_CONNECT_TIMEOUT, transport_options: nil, secrets: SecretsResolver.new)
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
          **ssh_options,
          port: port || DEFAULT_PORT,
          password: password&.value,
          timeout: connect_timeout,
          non_interactive: true,
        )
      end

      # Builds Net::SSH.start options from the node, resolving secrets.
      #
      # @return [Hash{Symbol => Object}] net-ssh options, with only the fields the node sets
      # @raise [Secret::Unavailable] when a referenced secret cannot be read
      #: () -> Hash[Symbol, untyped]
      private def ssh_options
        ssh = transport_options&.ssh
        return {} unless ssh

        options = {} #: Hash[Symbol, untyped]
        options[:config] = ssh.use_ssh_config if ssh.has_use_ssh_config?
        LIST_OPTIONS.each do |name|
          values = ssh.public_send(name).to_a
          options[name] = values unless values.empty?
        end
        key_options(ssh, options)
        options[:keys_only] = true if ssh.keys_only
        options[:passphrase] = secrets.maybe(ssh.passphrase)&.value if ssh.passphrase
        options[:number_of_password_prompts] = ssh.number_of_password_prompts if ssh.number_of_password_prompts.positive?
        verification = Must.be_a(ssh.verify_host_key, Symbol)
        options[:verify_host_key] = VERIFY_HOST_KEY.fetch(verification) unless verification == :HOST_KEY_VERIFICATION_UNSPECIFIED
        options[:compression] = true if ssh.compression
        options[:forward_agent] = true if ssh.forward_agent
        options[:proxy] = Net::SSH::Proxy::Command.new(ssh.proxy_command) unless ssh.proxy_command.empty?
        options
      end

      # Sets the keys and key_data options from the keys of the node.
      #
      # @param ssh [Proto::V1::SshOptions] options of the node
      # @param options [Hash{Symbol => Object}] net-ssh options to add to
      # @return [void]
      # @raise [Secret::Unavailable] when a referenced secret cannot be read
      #: (Proto::V1::SshOptions ssh, Hash[Symbol, untyped] options) -> void
      private def key_options(ssh, options)
        paths, raws = ssh.keys.partition { _1.source == :path }
        options[:keys] = paths.map(&:path) unless paths.empty?
        options[:key_data] = raws.map { secrets.maybe(_1.raw)&.value } unless raws.empty?
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
