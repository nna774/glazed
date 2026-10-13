# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'glazed'
require 'glazed/proto'
require 'glazed/storages'

module Glazed
  module Steps
    # Named storages shared by the steps of a workflow.
    class Context
      # Raised when a step names a storage that is not configured.
      class UnknownStorage < Glazed::Error; end

      # @param storages [Hash{String => Storages::Base}] storages by name
      #: (storages: Hash[String, Storages::Base]) -> void
      def initialize(storages:)
        @storages = storages #: Hash[String, Storages::Base]
      end

      # Builds every configured storage.
      #
      # @param storages [Google::Protobuf::Map] storage configs by name, from {Proto::V1::Config#storages}
      # @return [Context] the context
      # @raise [Storages::MissingBackend] when a storage config sets no backend
      #: (Google::Protobuf::Map[String, Proto::V1::StorageConfig] storages) -> Context
      def self.from_proto(storages)
        # Map#to_h would turn the messages into hashes.
        built = {} #: Hash[String, Storages::Base]
        storages.each { |name, config| built[name] = Storages.build(config) }
        new(storages: built)
      end

      # @param name [String] storage name
      # @return [Storages::Base] the storage
      # @raise [UnknownStorage] when no storage has that name
      #: (String name) -> Storages::Base
      def storage(name)
        @storages.fetch(name) { raise UnknownStorage, "no storage named #{name.inspect}" }
      end

      # Reads an artifact's content from its storage.
      #
      # @param artifact [Proto::V1::Artifact] the artifact
      # @return [String] its content
      # @raise [UnknownStorage] when the artifact's storage is not configured
      #: (Proto::V1::Artifact artifact) -> String
      def read(artifact)
        pointer = artifact.pointer or raise ArgumentError, "artifact in #{artifact.storage} has no pointer"
        storage(artifact.storage).read(pointer)
      end
    end
  end
end
