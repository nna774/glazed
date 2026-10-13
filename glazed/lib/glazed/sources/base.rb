# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'google/protobuf'
require 'glazed'
require 'glazed/proto'
require 'glazed/proto_json'

module Glazed
  module Sources
    # Inventory provider. Subclasses implement {.from_proto} and {#nodes}.
    class Base
      # Raised when inventory is malformed or a node lacks a name or dialect.
      class InvalidInventory < Glazed::Error; end

      # Node fields merged key by key with defaults.
      MAP_FIELDS = %w[params secrets].freeze #: Array[String]

      # Builds a provider from its settings message.
      #
      # @param settings [Google::Protobuf::MessageExts] provider settings from {Proto::V1::InventorySource}
      # @return [Base] the provider
      #: (Google::Protobuf::MessageExts settings) -> Base
      def self.from_proto(settings) = raise NotImplementedError

      # Reads the nodes.
      #
      # @return [Array<Proto::V1::Node>] nodes, each with a name and a dialect
      #: () -> Array[Proto::V1::Node]
      def nodes = raise NotImplementedError

      # @return [String] where the nodes come from, for error messages
      #: () -> String
      def description = self.class.name.to_s

      # Builds the nodes of an {Proto::V1::InventoryFile} document, filling
      # fields each node leaves unset from its defaults. The params and secrets
      # maps are merged key by key.
      #
      # @param document [Hash{String => Object}] the inventory file as decoded JSON
      # @param origin [String] where the document comes from, for error messages
      # @return [Array<Proto::V1::Node>] the nodes
      # @raise [InvalidInventory] when a node is malformed or lacks a name or dialect
      #: (Hash[String, untyped] document, origin: String) -> Array[Proto::V1::Node]
      private def nodes_from(document, origin:)
        defaults = document.fetch('defaults', {}) #: Hash[String, untyped]
        nodes = document.fetch('nodes', []) #: Array[Hash[String, untyped]]
        nodes.map do |attributes|
          merged = defaults.merge(attributes) do |key, default, value|
            MAP_FIELDS.include?(key) ? default.merge(value) : value
          end
          node = ProtoJson.load(Proto::V1::Node, JSON.generate(merged))
          raise InvalidInventory, "#{origin}: a node has no name" if node.name.empty?
          raise InvalidInventory, "#{origin}: node #{node.name.inspect} has no dialect" if node.dialect.empty?

          node
        rescue Google::Protobuf::ParseError => e
          raise InvalidInventory, "#{origin}: #{e.message}"
        end
      end
    end
  end
end
