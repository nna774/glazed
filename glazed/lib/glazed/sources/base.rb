# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'glazed'
require 'glazed/proto'

module Glazed
  module Sources
    # Inventory provider. Subclasses implement {.from_proto} and {#nodes}.
    class Base
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
    end
  end
end
