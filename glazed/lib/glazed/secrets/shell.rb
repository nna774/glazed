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
    # Secret printed by a command, such as a password manager's CLI, run each
    # time the value is read.
    #
    # @example
    #   Glazed::Secrets::Shell.new(run: 'pass show network/enable').value
    class Shell < Base
      # Seconds before the command is killed when the settings set none.
      DEFAULT_TIMEOUT = 30 #: Integer

      # @param run [String] command line, run by /bin/sh -c
      # @param timeout [Numeric] seconds before the command is killed
      #: (run: String, ?timeout: Numeric) -> void
      def initialize(run:, timeout: DEFAULT_TIMEOUT)
        super()
        @run = run #: String
        @timeout = timeout #: Numeric
      end

      # Builds a source from {Proto::V1::ShellSecret}.
      #
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::ShellSecret}
      # @return [Shell] the source
      # @raise [Must::Violation] when settings is another message
      #: (Google::Protobuf::MessageExts settings) -> Shell
      def self.from_proto(settings)
        shell = Must.be_a(settings, Proto::V1::ShellSecret)
        new(run: shell.run, timeout: shell.timeout_seconds.zero? ? DEFAULT_TIMEOUT : shell.timeout_seconds)
      end

      # @return [String] command line
      #: String
      attr_reader :run

      # @return [Numeric] seconds before the command is killed
      #: Numeric
      attr_reader :timeout

      # Runs the command and reads the value it prints.
      #
      # @return [String] stdout without one trailing newline
      # @raise [Secret::Unavailable] when the command exits non-zero or does not finish in time
      #: () -> String
      def value
        ShellCommand.new(run:, env: {}, stdin: '', timeout:).call.delete_suffix("\n")
      rescue ShellCommand::Failed, TimeoutError => e
        raise Secret::Unavailable, "secret command failed: #{e.message}"
      end
    end
  end
end
