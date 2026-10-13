# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/proto'
require 'glazed/secret'
require 'glazed/secrets_resolver'

module Glazed
  module Transports
    # Byte stream to a device. Subclasses implement the abstract methods.
    class Base
      # Default seconds to wait for a connection.
      DEFAULT_CONNECT_TIMEOUT = 15 #: Integer

      # @param host [String] hostname or address
      # @param port [Integer, nil] port, or nil for the transport's default
      # @param username [String] login user name
      # @param password [Secret, nil] login password
      # @param connect_timeout [Numeric] seconds to wait for a connection
      # @param transport_options [Proto::V1::TransportOptions, nil] per-transport connection options
      # @param secrets [SecretsResolver] reads secrets in the transport options
      #: (host: String, port: Integer?, username: String, password: Secret?, ?connect_timeout: Numeric, ?transport_options: Proto::V1::TransportOptions?, ?secrets: SecretsResolver) -> void
      def initialize(host:, port:, username:, password:, connect_timeout: DEFAULT_CONNECT_TIMEOUT, transport_options: nil, secrets: SecretsResolver.new)
        @host = host #: String
        @port = port #: Integer?
        @username = username #: String
        @password = password #: Secret?
        @connect_timeout = connect_timeout #: Numeric
        @transport_options = transport_options #: Proto::V1::TransportOptions?
        @secrets = secrets #: SecretsResolver
        @pty_options = {} #: Hash[Symbol, untyped]
      end

      # @return [String] hostname or address
      #: String
      attr_reader :host
      # @return [Integer, nil] port, or nil for the transport's default
      #: Integer?
      attr_reader :port
      # @return [String] login user name
      #: String
      attr_reader :username
      # @return [Secret, nil] login password
      #: Secret?
      attr_reader :password
      # @return [Numeric] seconds to wait for a connection
      #: Numeric
      attr_reader :connect_timeout
      # @return [Proto::V1::TransportOptions, nil] per-transport connection options
      #: Proto::V1::TransportOptions?
      attr_reader :transport_options
      # @return [SecretsResolver] reads secrets in the transport options
      #: SecretsResolver
      attr_reader :secrets
      # @return [Hash{Symbol => Object}] terminal settings overriding the transport's defaults; ignored by transports without a PTY
      #: Hash[Symbol, untyped]
      attr_accessor :pty_options

      # Connects to the device.
      #
      # @return [void]
      #: () -> void
      def open = raise NotImplementedError

      # Sends data to the interactive session.
      #
      # @param data [String] bytes to send
      # @return [void]
      #: (String data) -> void
      def write(data) = raise NotImplementedError

      # Receives data from the interactive session.
      #
      # @param timeout [Numeric] seconds to wait for data
      # @return [String, nil] received data, empty when none arrived in time, nil at end of stream
      #: (timeout: Numeric) -> String?
      def read(timeout:) = raise NotImplementedError

      # Closes the connection. Safe to call more than once.
      #
      # @return [void]
      #: () -> void
      def close = raise NotImplementedError

      # Whether the transport authenticates the user itself, so no login
      # prompts are expected in the session.
      #
      # @return [Boolean]
      #: () -> bool
      def authenticates? = false

      # Whether {#exec} is supported.
      #
      # @return [Boolean]
      #: () -> bool
      def exec? = false

      # Runs one command outside the interactive session.
      #
      # @param command [String] command line
      # @param timeout [Numeric] seconds to wait for the command to finish
      # @return [String] command output
      # @raise [NotImplementedError] when the transport has no exec
      #: (String command, timeout: Numeric) -> String
      def exec(command, timeout:) = raise NotImplementedError, "#{self.class} does not support exec"

      # @return [Float] monotonic clock reading in seconds
      #: () -> Float
      private def now = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
    end
  end
end
