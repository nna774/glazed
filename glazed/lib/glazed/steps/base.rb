# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'glazed'
require 'glazed/proto'
require 'glazed/storages/base'

module Glazed
  module Steps
    # Base of workflow steps. Subclass {NodeStep} or {BatchStep}.
    class Base
      # Raised when a state lacks an artifact the step reads.
      class MissingArtifact < Glazed::Error; end

      # Builds a step from its settings message.
      #
      # @param name [String] step name, unique within the workflow
      # @param settings [Google::Protobuf::MessageExts] action settings from {Proto::V1::Step}
      # @param context [Context] named storages
      # @return [Base] the step
      #: (String name, Google::Protobuf::MessageExts settings, context: Context) -> Base
      def self.from_proto(name, settings, context:) = raise NotImplementedError

      # @param name [String] step name, unique within the workflow
      #: (name: String) -> void
      def initialize(name:)
        @name = name #: String
      end

      # @return [String] step name
      #: String
      attr_reader :name

      # @return [Array<String>] names of the artifacts the step reads
      #: () -> Array[String]
      def inputs = []

      # @return [Array<String>] names of the artifacts the step produces
      #: () -> Array[String]
      def outputs = []

      # @param state [Proto::V1::NodeState] state to read from
      # @param artifact [String] artifact name
      # @return [Proto::V1::Artifact] the artifact
      # @raise [MissingArtifact] when the state lacks it
      #: (Proto::V1::NodeState state, String artifact) -> Proto::V1::Artifact
      private def artifact(state, artifact)
        state.artifacts[artifact] or raise MissingArtifact, "#{name}: #{state.node&.name} has no artifact #{artifact.inspect}"
      end

      # @param storage_name [String] name of the storage written to
      # @param result [Storages::Base::WriteResult] outcome of the write
      # @return [Proto::V1::Artifact] artifact naming the stored content and whether it changed
      #: (String storage_name, Storages::Base::WriteResult result) -> Proto::V1::Artifact
      private def stored(storage_name, result)
        Proto::V1::Artifact.new(storage: storage_name, pointer: result.pointer, changed: result.changed?)
      end

      # @param state [Proto::V1::NodeState] state to extend
      # @param artifacts [Hash{String => Proto::V1::Artifact}] artifacts to add
      # @return [Proto::V1::NodeState] a copy of the state with the artifacts
      #: (Proto::V1::NodeState state, Hash[String, Proto::V1::Artifact] artifacts) -> Proto::V1::NodeState
      private def with_artifacts(state, artifacts)
        copy = Proto::V1::NodeState.decode(Proto::V1::NodeState.encode(state))
        artifacts.each { |key, value| copy.artifacts[key] = value }
        copy
      end
    end

    # Step run for each node independently.
    class NodeStep < Base
      # @param state [Proto::V1::NodeState] the node and its artifacts
      # @return [Proto::V1::NodeState] the state with the step's outputs added
      #: (Proto::V1::NodeState state) -> Proto::V1::NodeState
      def call(state) = raise NotImplementedError
    end

    # Step run once with every node that completed the steps before it.
    class BatchStep < Base
      # @param batch [Proto::V1::BatchState] node states
      # @return [Proto::V1::BatchState] the states with the step's outputs added
      #: (Proto::V1::BatchState batch) -> Proto::V1::BatchState
      def call(batch) = raise NotImplementedError
    end
  end
end
