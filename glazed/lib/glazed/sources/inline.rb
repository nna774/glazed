# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/proto_json'
require 'glazed/sources'
require 'glazed/sources/base'
require 'glazed/validation'

module Glazed
  module Sources
    # Inventory written in the config itself, for setups that keep everything
    # in one file. Defaults apply as in {JsonFiles}.
    #
    # @example Inventory source
    #   {"inline": {"defaults": {"dialect": "ios"}, "nodes": [{"name": "rt1"}]}}
    class Inline < Base
      # @param inventory [Proto::V1::InventoryFile] nodes and their defaults
      #: (inventory: Proto::V1::InventoryFile) -> void
      def initialize(inventory:)
        super()
        @inventory = inventory #: Proto::V1::InventoryFile
      end

      # Builds a provider from an inline {Proto::V1::InventoryFile}.
      #
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::InventoryFile}
      # @return [Inline] the provider
      # @raise [Must::Violation] when settings is another message
      # @raise [InvalidMessage] when the inventory breaks the rules of its schema
      #: (Google::Protobuf::MessageExts settings) -> Inline
      def self.from_proto(settings)
        inventory = Must.be_a(settings, Proto::V1::InventoryFile)
        Validation.validate!(inventory, origin: 'inline inventory')
        new(inventory:)
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
      def description = 'inline inventory'
    end
  end
end
