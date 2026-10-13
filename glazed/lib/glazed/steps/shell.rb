# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/must'
require 'glazed/proto'
require 'glazed/proto_json'
require 'glazed/shell_command'
require 'glazed/steps'
require 'glazed/storages'

module Glazed
  module Steps
    # Per node: runs a command with /bin/sh -c. The input artifact's content is
    # on stdin and stdout becomes the output artifact; both are optional.
    #
    # @example Step definition
    #   {"name": "normalize", "shell": {"run": "sed -e '/^ntp clock-period/d'",
    #    "input": "raw", "output": "normalized", "storage": "staging"}}
    class Shell < NodeStep
      # Seconds a command may run when the definition sets none.
      DEFAULT_TIMEOUT = 300 #: Integer

      # @param name [String] step name
      # @param run [String] command line
      # @param input [String, nil] artifact written to stdin
      # @param output [String, nil] artifact produced from stdout
      # @param storage_name [String, nil] storage for the output, by name
      # @param context [StepContext] named storages
      # @param timeout [Numeric] seconds before the command is killed
      # @raise [StepContext::UnknownStorage] when the storage is not configured
      #: (name: String, run: String, input: String?, output: String?, storage_name: String?, context: StepContext, ?timeout: Numeric) -> void
      def initialize(name:, run:, input:, output:, storage_name:, context:, timeout: DEFAULT_TIMEOUT)
        super(name:)
        @run = run #: String
        @input = input #: String?
        @output = output #: String?
        @storage_name = storage_name #: String?
        @storage = (context.storage(storage_name) if storage_name) #: Storages::Base?
        @context = context #: StepContext
        @timeout = timeout #: Numeric
      end

      # Builds the step from {Proto::V1::ShellStep}.
      #
      # @param name [String] step name
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::ShellStep}
      # @param context [StepContext] named storages
      # @return [Shell] the step
      #: (String name, Google::Protobuf::MessageExts settings, context: StepContext) -> Shell
      def self.from_proto(name, settings, context:)
        shell = Must.be_a(settings, Proto::V1::ShellStep)
        new(
          name:, run: shell.run, context:,
          input: shell.input.empty? ? nil : shell.input,
          output: shell.output.empty? ? nil : shell.output,
          storage_name: shell.storage.empty? ? nil : shell.storage,
          timeout: shell.timeout_seconds.zero? ? DEFAULT_TIMEOUT : shell.timeout_seconds,
        )
      end

      # @return [Array<String>] the artifact written to stdin, if any
      #: () -> Array[String]
      def inputs = [@input].compact

      # @return [Array<String>] the artifact produced from stdout, if any
      #: () -> Array[String]
      def outputs = [@output].compact

      # @param state [Proto::V1::NodeState] the node and its artifacts
      # @return [Proto::V1::NodeState] the state, with the output artifact when configured
      # @raise [ShellCommand::Failed] when the command exits non-zero
      # @raise [TimeoutError] when the command does not finish in time
      # @raise [MissingArtifact] when the input artifact is absent
      #: (Proto::V1::NodeState state) -> Proto::V1::NodeState
      def call(state)
        node = state.node or raise ArgumentError, "#{name}: state has no node"
        input = @input
        stdin = input ? @context.read(artifact(state, input)) : ''
        stdout = ShellCommand.new(run: @run, env: env(node), stdin:, timeout: @timeout).call

        output = @output
        storage = @storage
        storage_name = @storage_name
        return state unless output && storage && storage_name

        result = storage.write(key: Storages.key_for(node), content: stdout, message: "#{node.name}: #{name}")
        with_artifacts(state, output => stored(storage_name, result))
      end

      # @param node [Proto::V1::Node] the node
      # @return [Hash{String => String}] environment describing the step and node
      #: (Proto::V1::Node node) -> Hash[String, String]
      private def env(node)
        {
          'GLAZED_STEP' => name,
          'GLAZED_NODE_NAME' => node.name,
          'GLAZED_NODE_GROUP' => node.group,
          'GLAZED_NODE_DIALECT' => node.dialect,
          'GLAZED_NODE_HOST' => node.host.empty? ? node.name : node.host,
          'GLAZED_NODE' => ProtoJson.dump(node),
        }
      end
    end
  end
end
