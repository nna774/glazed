# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/must'
require 'glazed/proto'
require 'glazed/proto_json'
require 'glazed/shell_command'
require 'glazed/steps'

module Glazed
  module Steps
    # Batch: runs a command with /bin/sh -c once, with the
    # {Proto::V1::BatchState} of every node that got this far as ProtoJSON on
    # stdin, for hooks such as notifications.
    #
    # @example Step definition
    #   {"name": "notify", "batch_shell": {"run": "bin/notify-changes"}}
    class BatchShell < BatchStep
      # Seconds a command may run when the definition sets none.
      DEFAULT_TIMEOUT = 300 #: Integer

      # @param name [String] step name
      # @param run [String] command line
      # @param timeout [Numeric] seconds before the command is killed
      #: (name: String, run: String, ?timeout: Numeric) -> void
      def initialize(name:, run:, timeout: DEFAULT_TIMEOUT)
        super(name:)
        @run = run #: String
        @timeout = timeout #: Numeric
      end

      # Builds the step from {Proto::V1::BatchShellStep}.
      #
      # @param name [String] step name
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::BatchShellStep}
      # @param context [Context] named storages, unused
      # @return [BatchShell] the step
      # @raise [InvalidStep] when run is missing
      #: (String name, Google::Protobuf::MessageExts settings, context: Context) -> BatchShell
      def self.from_proto(name, settings, context:)
        shell = Must.be_a(settings, Proto::V1::BatchShellStep)
        raise InvalidStep, "#{name}: batch_shell needs run" if shell.run.empty?

        new(name:, run: shell.run, timeout: shell.timeout_seconds.zero? ? DEFAULT_TIMEOUT : shell.timeout_seconds)
      end

      # @param batch [Proto::V1::BatchState] node states
      # @return [Proto::V1::BatchState] the same states
      # @raise [ShellCommand::Failed] when the command exits non-zero
      # @raise [TimeoutError] when the command does not finish in time
      #: (Proto::V1::BatchState batch) -> Proto::V1::BatchState
      def call(batch)
        ShellCommand.new(run: @run, env: {'GLAZED_STEP' => name}, stdin: ProtoJson.dump(batch), timeout: @timeout).call
        batch
      end
    end
  end
end
