# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'glazed'
require 'glazed/proto'
require 'glazed/secrets_resolver'
require 'glazed/storage_context'
require 'glazed/storages'

module Glazed
  # Named storages shared by the steps of a workflow, the resolver of the
  # secrets they refer to, and where steps report progress.
  class StepContext
    # Raised when a step names a storage that is not configured.
    class UnknownStorage < Glazed::Error; end

    # @return [Proto::V1::Redaction, nil] redaction settings shared by redact steps
    #: Proto::V1::Redaction?
    attr_reader :redaction

    # @param storages [Hash{String => Storages::Base}] storages by name
    # @param redaction [Proto::V1::Redaction, nil] redaction settings shared by redact steps
    # @param listener [Proc] receives progress events from steps, possibly from several threads at once
    # @param secrets [SecretsResolver] reads secrets of nodes and settings
    #: (storages: Hash[String, Storages::Base], ?redaction: Proto::V1::Redaction?, ?listener: Runner::listener, ?secrets: SecretsResolver) -> void
    def initialize(storages:, redaction: nil, listener: ->(_event) {}, secrets: SecretsResolver.new)
      @storages = storages #: Hash[String, Storages::Base]
      @redaction = redaction #: Proto::V1::Redaction?
      @listener = listener #: Runner::listener
      @secrets = secrets #: SecretsResolver
    end

    # @return [SecretsResolver] reads secrets of nodes and settings
    #: SecretsResolver
    attr_reader :secrets

    # Builds every configured storage, with one secrets resolver for the storages and the steps.
    #
    # @param storages [Google::Protobuf::Map] storage configs by name, from {Proto::V1::Config#storages}
    # @param redaction [Proto::V1::Redaction, nil] redaction settings shared by redact steps, from {Proto::V1::Config#redaction}
    # @param listener [Proc] receives progress events from steps, possibly from several threads at once
    # @return [StepContext] the context
    # @raise [Storages::MissingBackend] when a storage config sets no backend
    #: (Google::Protobuf::Map[String, Proto::V1::StorageConfig] storages, ?redaction: Proto::V1::Redaction?, ?listener: Runner::listener) -> StepContext
    def self.from_proto(storages, redaction: nil, listener: ->(_event) {})
      secrets = SecretsResolver.new
      storage_context = StorageContext.new(secrets:)
      # Map#to_h would turn the messages into hashes.
      built = {} #: Hash[String, Storages::Base]
      storages.each { |name, config| built[name] = Storages.build(config, context: storage_context) }
      new(storages: built, redaction:, listener:, secrets:)
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
