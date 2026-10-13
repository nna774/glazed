# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'glazed'
require 'glazed/proto'
require 'glazed/storages'

module Glazed
  # Named storages shared by the steps of a workflow, and where steps report progress.
  class StepContext
    # Raised when a step names a storage that is not configured.
    class UnknownStorage < Glazed::Error; end

    # @param storages [Hash{String => Storages::Base}] storages by name
    # @param listener [Proc] receives progress events from steps, possibly from several threads at once
    #: (storages: Hash[String, Storages::Base], ?listener: Runner::listener) -> void
    def initialize(storages:, listener: ->(_event) {})
      @storages = storages #: Hash[String, Storages::Base]
      @listener = listener #: Runner::listener
    end

    # Builds every configured storage.
    #
    # @param storages [Google::Protobuf::Map] storage configs by name, from {Proto::V1::Config#storages}
    # @param listener [Proc] receives progress events from steps, possibly from several threads at once
    # @return [StepContext] the context
    # @raise [Storages::MissingBackend] when a storage config sets no backend
    #: (Google::Protobuf::Map[String, Proto::V1::StorageConfig] storages, ?listener: Runner::listener) -> StepContext
    def self.from_proto(storages, listener: ->(_event) {})
      # Map#to_h would turn the messages into hashes.
      built = {} #: Hash[String, Storages::Base]
      storages.each { |name, config| built[name] = Storages.build(config) }
      new(storages: built, listener:)
    end

    # Reports progress of a step.
    #
    # @param event [Hash{Symbol => String, Integer, Boolean, nil}] event fields
    # @return [void]
    #: (**Runner::event_value event) -> void
    def notify(**event) = @listener.call(event)

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
