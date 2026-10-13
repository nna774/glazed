# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/shell_command'
require 'glazed/sources'
require 'glazed/sources/base'

module Glazed
  module Sources
    # Inventory printed by a command as ProtoJSON of {Proto::V1::InventoryFile},
    # for nodes kept in another system.
    #
    # @example
    #   Glazed::Sources::Command.new(run: 'bin/inventory --site hnd').nodes
    class Command < Base
      # Seconds before the command is killed when the settings set none.
      DEFAULT_TIMEOUT = 300 #: Integer

      # @param run [String] command line, run by /bin/sh -c
      # @param timeout [Numeric] seconds before the command is killed
      #: (run: String, ?timeout: Numeric) -> void
      def initialize(run:, timeout: DEFAULT_TIMEOUT)
        super()
        @run = run #: String
        @timeout = timeout #: Numeric
      end

      # Builds a provider from {Proto::V1::CommandInventory}.
      #
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::CommandInventory}
      # @return [Command] the provider
      # @raise [Must::Violation] when settings is another message
      #: (Google::Protobuf::MessageExts settings) -> Command
      def self.from_proto(settings)
        command = Must.be_a(settings, Proto::V1::CommandInventory)
        new(run: command.run, timeout: command.timeout_seconds.zero? ? DEFAULT_TIMEOUT : command.timeout_seconds)
      end

      # @return [String] command line
      #: String
      attr_reader :run

      # @return [Numeric] seconds before the command is killed
      #: Numeric
      attr_reader :timeout

      # Runs the command and reads the nodes it prints.
      #
      # @return [Array<Proto::V1::Node>] nodes with defaults applied
      # @raise [ShellCommand::Failed] when the command exits non-zero
      # @raise [TimeoutError] when the command does not finish in time
      # @raise [InvalidInventory] when the output is not an inventory file
      # @raise [InvalidMessage] when the output breaks the rules of its schema
      #: () -> Array[Proto::V1::Node]
      def nodes = nodes_from_json(ShellCommand.new(run:, env: {}, stdin: '', timeout:).call, origin: description)

      # @return [String] the command line
      #: () -> String
      def description = "command #{run}"
    end
  end
end
