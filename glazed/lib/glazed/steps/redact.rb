# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/redactor'
require 'glazed/steps'
require 'glazed/storages'

module Glazed
  module Steps
    # Per node: hides secrets in an artifact using the node dialect's sensitive
    # patterns, and stores the result as another artifact.
    #
    # @example Step definition
    #   {"name": "redact", "redact": {"input": "raw", "output": "redacted", "storage": "staging",
    #    "redaction": {"mode": "MODE_HMAC", "hmac_key": {"env": "GLAZED_HMAC_KEY"}}}}
    class Redact < NodeStep
      # @param name [String] step name
      # @param input [String] artifact to read
      # @param output [String] artifact to produce
      # @param storage_name [String] storage to write to, by name
      # @param redaction [Proto::V1::Redaction] how secrets are hidden
      # @param context [StepContext] named storages
      # @raise [StepContext::UnknownStorage] when the storage is not configured
      #: (name: String, input: String, output: String, storage_name: String, redaction: Proto::V1::Redaction, context: StepContext) -> void
      def initialize(name:, input:, output:, storage_name:, redaction:, context:)
        super(name:)
        @input = input #: String
        @output = output #: String
        @storage_name = storage_name #: String
        @storage = context.storage(storage_name) #: Storages::Base
        @redaction = redaction #: Proto::V1::Redaction
        @context = context #: StepContext
      end

      # Builds the step from {Proto::V1::RedactStep}.
      #
      # @param name [String] step name
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::RedactStep}
      # @param context [StepContext] named storages
      # @return [Redact] the step
      #: (String name, Google::Protobuf::MessageExts settings, context: StepContext) -> Redact
      def self.from_proto(name, settings, context:)
        redact = Must.be_a(settings, Proto::V1::RedactStep)
        new(
          name:, input: redact.input, output: redact.output, storage_name: redact.storage,
          redaction: redact.redaction || Proto::V1::Redaction.new, context:,
        )
      end

      # @return [Array<String>] the read artifact
      #: () -> Array[String]
      def inputs = [@input]

      # @return [Array<String>] the produced artifact
      #: () -> Array[String]
      def outputs = [@output]

      # @param state [Proto::V1::NodeState] the node and its input artifact
      # @return [Proto::V1::NodeState] the state with the redacted artifact
      # @raise [MissingArtifact] when the input artifact is absent
      # @raise [Glazed::Error] when reading, redacting or storing fails
      #: (Proto::V1::NodeState state) -> Proto::V1::NodeState
      def call(state)
        node = state.node or raise ArgumentError, "#{name}: state has no node"
        redactor = Redactor.from_proto(
          @redaction, patterns: Dialects.find(node.dialect).sensitive_patterns, global: @context.redaction, secrets: @context.secrets,
        )
        content = redactor.call(@context.read(artifact(state, @input)))
        result = @storage.write(key: Storages.key_for(node), content:, message: "#{node.name}: #{name}")
        with_artifacts(state, @output => stored(@storage_name, result))
      end
    end
  end
end
