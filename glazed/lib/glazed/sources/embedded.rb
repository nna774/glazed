# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/proto_json'
require 'glazed/sources'
require 'glazed/sources/base'

module Glazed
  module Sources
    # Inventory written in the config itself, for setups that keep everything
    # in one file. Defaults apply as in {JsonFiles}.
    #
    # @example Inventory source
    #   {"embedded": {"defaults": {"dialect": "ios"}, "nodes": [{"name": "rt1"}]}}
    class Embedded < Base
      # @param inventory [Proto::V1::InventoryFile] nodes and their defaults
      #: (inventory: Proto::V1::InventoryFile) -> void
      def initialize(inventory:)
        super()
        @inventory = inventory #: Proto::V1::InventoryFile
      end

      # Builds a provider from an embedded {Proto::V1::InventoryFile}.
      #
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::InventoryFile}
      # @return [Embedded] the provider
      # @raise [Must::Violation] when settings is another message
      #: (Google::Protobuf::MessageExts settings) -> Embedded
      def self.from_proto(settings)
        new(inventory: Must.be_a(settings, Proto::V1::InventoryFile))
      end

      # @return [Array<Proto::V1::Node>] the nodes with defaults applied
      # @raise [InvalidInventory] when a node lacks a name or dialect
      #: () -> Array[Proto::V1::Node]
      def nodes
        # ProtoJSON omits unset fields, so defaults merge as they do for files.
        document = JSON.parse(ProtoJson.dump(@inventory)) #: Hash[String, untyped]
        nodes_from(document, origin: description)
      end

      # @return [String] where the nodes come from
      #: () -> String
      def description = 'embedded inventory'
    end
  end
end
