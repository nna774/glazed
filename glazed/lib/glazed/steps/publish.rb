# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/must'
require 'glazed/proto'
require 'glazed/steps'
require 'glazed/storages'

module Glazed
  module Steps
    # Batch: writes an artifact of every node into a storage, as one change
    # per changed node, such as a commit titled "glazed: rt1".
    #
    # @example Step definition
    #   {"name": "publish", "publish": {"input": "redacted", "storage": "team"}}
    class Publish < BatchStep
      # @param name [String] step name
      # @param input [String] artifact to read from each node
      # @param storage_name [String] storage to write to, by name
      # @param output [String, nil] artifact recording the written locations
      # @param context [StepContext] named storages
      # @raise [StepContext::UnknownStorage] when the storage is not configured
      #: (name: String, input: String, storage_name: String, output: String?, context: StepContext) -> void
      def initialize(name:, input:, storage_name:, output:, context:)
        super(name:)
        @input = input #: String
        @storage_name = storage_name #: String
        @storage = context.storage(storage_name) #: Storages::Base
        @output = output #: String?
        @context = context #: StepContext
      end

      # Builds the step from {Proto::V1::PublishStep}.
      #
      # @param name [String] step name
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::PublishStep}
      # @param context [StepContext] named storages
      # @return [Publish] the step
      #: (String name, Google::Protobuf::MessageExts settings, context: StepContext) -> Publish
      def self.from_proto(name, settings, context:)
        publish = Must.be_a(settings, Proto::V1::PublishStep)
        new(name:, input: publish.input, storage_name: publish.storage, output: publish.output.empty? ? nil : publish.output, context:)
      end

      # @return [Array<String>] the read artifact
      #: () -> Array[String]
      def inputs = [@input]

      # @return [Array<String>] the recorded artifact, if any
      #: () -> Array[String]
      def outputs = [@output].compact

      # @param batch [Proto::V1::BatchState] node states holding the input artifact
      # @return [Proto::V1::BatchState] the states, with the output artifact when configured
      # @raise [MissingArtifact] when a node lacks the input artifact
      # @raise [Glazed::Error] when reading or storing fails
      #: (Proto::V1::BatchState batch) -> Proto::V1::BatchState
      def call(batch)
        states = batch.nodes.to_a
        return batch if states.empty?

        names = {} #: Hash[String, String]
        files = states.map do |state|
          node = state.node or raise ArgumentError, "#{name}: state has no node"
          key = Storages.key_for(node)
          names[key] = node.name
          [key, @context.read(artifact(state, @input))] #: Storages::Base::file
        end
        results = @storage.write_all(files, message: ->(key) { "glazed: #{names.fetch(key, key)}" })
        output = @output
        return batch unless output

        nodes = states.zip(results).map do |state, result|
          with_artifacts(state, output => stored(@storage_name, Must.expect(result)))
        end
        Proto::V1::BatchState.new(nodes:)
      end
    end
  end
end
