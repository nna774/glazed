# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects'
require 'glazed/proto'
require 'glazed/redactor'
require 'glazed/steps'
require 'glazed/storages'

module Glazed
  module Steps
    # Redacts raw configurations and stores them together, as one commit where
    # the storage supports it.
    #
    # @example
    #   publish = Glazed::Steps::Publish.new(raw_storage:, redacted_storage:, redaction:)
    #   publish.call(Glazed::Proto::V1::PublishRequest.new(entries: fetch_results))
    class Publish
      # Node names listed in a commit message before it is shortened.
      MESSAGE_NAMES = 5 #: Integer

      # @param raw_storage [Storages::Base] storage the fetch step wrote to
      # @param redacted_storage [Storages::Base] storage for redacted configuration
      # @param redaction [Proto::V1::Redaction] how secrets are hidden
      #: (raw_storage: Storages::Base, redacted_storage: Storages::Base, redaction: Proto::V1::Redaction) -> void
      def initialize(raw_storage:, redacted_storage:, redaction:)
        @raw_storage = raw_storage #: Storages::Base
        @redacted_storage = redacted_storage #: Storages::Base
        @redaction = redaction #: Proto::V1::Redaction
      end

      # @param request [Proto::V1::PublishRequest] fetch results to publish
      # @return [Proto::V1::PublishResult] locations of the redacted configurations
      # @raise [ArgumentError] when an entry lacks its node or raw pointer
      # @raise [Glazed::Error] when reading, redacting or storing fails
      #: (Proto::V1::PublishRequest request) -> Proto::V1::PublishResult
      def call(request)
        redactors = {} #: Hash[singleton(Dialects::Base), Redactor]
        names = [] #: Array[String]
        files = request.entries.map do |entry|
          node = entry.node or raise ArgumentError, 'publish entry has no node'
          raw = entry.raw or raise ArgumentError, "publish entry for #{node.name} has no raw pointer"
          dialect = Dialects.find(node.dialect)
          redactor = redactors[dialect] ||= Redactor.from_proto(@redaction, patterns: dialect.sensitive_patterns)
          names << node.name
          [Storages.key_for(node), redactor.call(@raw_storage.read(raw))] #: Storages::Base::file
        end
        return Proto::V1::PublishResult.new if files.empty?

        Proto::V1::PublishResult.new(redacted: @redacted_storage.write_all(files, message: message(names)))
      end

      # @param names [Array<String>] published node names
      # @return [String] commit message naming the nodes
      #: (Array[String] names) -> String
      private def message(names)
        listed = names.first(MESSAGE_NAMES).join(', ')
        rest = names.size - MESSAGE_NAMES
        rest.positive? ? "update #{listed} and #{rest} more" : "update #{listed}"
      end
    end
  end
end
