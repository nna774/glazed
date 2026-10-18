# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/must'
require 'glazed/proto'
require 'glazed/proto_json'
require 'glazed/shell_command'
require 'glazed/steps'
require 'glazed/durations'

module Glazed
  module Steps
    # Batch: runs a command line with /bin/sh -c, or a program with its
    # arguments, once with the {Proto::V1::BatchState} of every node that got
    # this far as ProtoJSON on stdin, for hooks such as notifications.
    #
    # @example Step definition
    #   {"name": "notify", "batch_command": {"run": "bin/notify-changes"}}
    class BatchCommand < BatchStep
      # Seconds a command may run when the definition sets none.
      DEFAULT_TIMEOUT = 300 #: Integer

      # @param name [String] step name
      # @param run [String, Array<String>] command line for /bin/sh -c, or program and its arguments
      # @param timeout [Numeric] seconds before the command is killed
      #: (name: String, run: String | Array[String], ?timeout: Numeric) -> void
      def initialize(name:, run:, timeout: DEFAULT_TIMEOUT)
        super(name:)
        @run = run #: String | Array[String]
        @timeout = timeout #: Numeric
      end

      # Builds the step from {Proto::V1::BatchCommandStep}.
      #
      # @param name [String] step name
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::BatchCommandStep}
      # @param context [StepContext] named storages, unused
      # @return [BatchCommand] the step
      #: (String name, Google::Protobuf::MessageExts settings, context: StepContext) -> BatchCommand
      def self.from_proto(name, settings, context:)
        command = Must.be_a(settings, Proto::V1::BatchCommandStep)
        new(name:, run: ShellCommand.run_of(command.run, command.exec), timeout: Durations.seconds(command.timeout, DEFAULT_TIMEOUT))
      end

      # @param batch [Proto::V1::BatchState] node states
      # @return [Proto::V1::BatchState] the same states
      # @raise [ShellCommand::Failed] when the command cannot start or exits non-zero
      # @raise [TimeoutError] when the command does not finish in time
      #: (Proto::V1::BatchState batch) -> Proto::V1::BatchState
      def call(batch)
        ShellCommand.new(run: @run, env: {'GLAZED_STEP' => name}, stdin: ProtoJson.dump(batch), timeout: @timeout).call
        batch
      end
    end
  end
end
