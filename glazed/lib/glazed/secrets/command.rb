# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/secret'
require 'glazed/secrets'
require 'glazed/shell_command'

module Glazed
  module Secrets
    # Secret printed by a command line run with /bin/sh -c, or by a program
    # run with its arguments, such as a password manager's CLI. It runs each
    # time the value is read.
    #
    # @example
    #   Glazed::Secrets::Command.new(run: 'pass show network/enable').value
    #   Glazed::Secrets::Command.new(run: %w[op read op://network/enable/password]).value
    class Command < Base
      # Seconds before the command is killed when the settings set none.
      DEFAULT_TIMEOUT = 30 #: Integer

      # @param run [String, Array<String>] command line for /bin/sh -c, or program and its arguments
      # @param timeout [Numeric] seconds before the command is killed
      #: (run: String | Array[String], ?timeout: Numeric) -> void
      def initialize(run:, timeout: DEFAULT_TIMEOUT)
        super()
        @run = run #: String | Array[String]
        @timeout = timeout #: Numeric
      end

      # Builds a source from {Proto::V1::CommandSecret}.
      #
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::CommandSecret}
      # @return [Command] the source
      # @raise [Must::Violation] when settings is another message
      #: (Google::Protobuf::MessageExts settings) -> Command
      def self.from_proto(settings)
        command = Must.be_a(settings, Proto::V1::CommandSecret)
        new(run: ShellCommand.run_of(command.run, command.exec), timeout: command.timeout_seconds.zero? ? DEFAULT_TIMEOUT : command.timeout_seconds)
      end

      # @return [String, Array<String>] command line, or program and its arguments
      #: String | Array[String]
      attr_reader :run

      # @return [Numeric] seconds before the command is killed
      #: Numeric
      attr_reader :timeout

      # Runs the command and reads the value it prints.
      #
      # @return [String] stdout without one trailing newline
      # @raise [Secret::Unavailable] when the command cannot start, exits non-zero or does not finish in time
      #: () -> String
      def value
        ShellCommand.new(run:, env: {}, stdin: '', timeout:).call.delete_suffix("\n")
      rescue ShellCommand::Failed, TimeoutError => e
        raise Secret::Unavailable, "secret command failed: #{e.message}"
      end
    end
  end
end
