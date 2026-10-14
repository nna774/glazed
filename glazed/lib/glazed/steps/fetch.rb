# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/cli_session'
require 'glazed/collector'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/steps'
require 'glazed/storages'

module Glazed
  module Steps
    # Per node: collects the node's configuration and stores it as an artifact.
    #
    # @example Step definition
    #   {"name": "fetch", "fetch": {"output": "raw", "storage": "vault"}}
    class Fetch < NodeStep
      # @param name [String] step name
      # @param output [String] artifact to produce
      # @param storage_name [String] storage to write to, by name
      # @param context [StepContext] named storages, and where progress is reported
      # @param timeout [Numeric] seconds to wait for each expected device output
      # @raise [StepContext::UnknownStorage] when the storage is not configured
      #: (name: String, output: String, storage_name: String, context: StepContext, ?timeout: Numeric) -> void
      def initialize(name:, output:, storage_name:, context:, timeout: CliSession::DEFAULT_TIMEOUT)
        super(name:)
        @output = output #: String
        @storage_name = storage_name #: String
        @context = context #: StepContext
        @storage = context.storage(storage_name) #: Storages::Base
        @timeout = timeout #: Numeric
      end

      # Builds the step from {Proto::V1::FetchStep}.
      #
      # @param name [String] step name
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::FetchStep}
      # @param context [StepContext] named storages
      # @return [Fetch] the step
      #: (String name, Google::Protobuf::MessageExts settings, context: StepContext) -> Fetch
      def self.from_proto(name, settings, context:)
        fetch = Must.be_a(settings, Proto::V1::FetchStep)
        timeout = fetch.timeout_seconds.zero? ? CliSession::DEFAULT_TIMEOUT : fetch.timeout_seconds
        new(name:, output: fetch.output, storage_name: fetch.storage, context:, timeout:)
      end

      # @return [Array<String>] the produced artifact
      #: () -> Array[String]
      def outputs = [@output]

      # @param state [Proto::V1::NodeState] the node
      # @return [Proto::V1::NodeState] the state with the collected configuration
      # @raise [ArgumentError] when the state has no node
      # @raise [Glazed::Error] when collecting or storing fails
      #: (Proto::V1::NodeState state) -> Proto::V1::NodeState
      def call(state)
        node = state.node or raise ArgumentError, "#{name}: state has no node"
        progress = ->(message) { @context.notify(level: 'info', step: name, node: node.name, message:) } #: ^(String) -> void
        config = Collector.new(node:, timeout: @timeout, progress:, secrets: @context.secrets).call
        result = @storage.write(key: Storages.key_for(node), content: config, message: "#{node.name}: #{name}")
        with_artifacts(state, @output => stored(@storage_name, result))
      end
    end
  end
end
