# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/finder'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/sources/base'

module Glazed
  # Namespace of inventory providers, looked up by name.
  module Sources
    # Raised when an inventory source names no provider.
    class MissingProvider < Glazed::Error; end
    # Raised when two nodes share a name.
    class DuplicateNode < Glazed::Error; end

    # Finds a provider class by snake_case name.
    #
    # @param name [String, Symbol] provider name, such as "json_files"
    # @return [Class<Base>] the provider class
    # @raise [Finder::NotFound] when there is none, for example when the gem providing it is not installed
    # @raise [Must::Violation] when the name resolves to something other than a provider
    #: (String | Symbol name) -> singleton(Base)
    def self.find(name)
      found = Finder.find(self, 'glazed/sources', name)
      return found if found.is_a?(Class) && found < Base

      raise Must::Violation, "#{found} is not an inventory provider"
    end

    # Builds the provider a source selects.
    #
    # @param source [Proto::V1::InventorySource] provider settings
    # @return [Base] the provider
    # @raise [MissingProvider] when no provider is set
    # @raise [Finder::NotFound] when the provider is not available
    #: (Proto::V1::InventorySource source) -> Base
    def self.build(source)
      provider = source.provider or raise MissingProvider, 'inventory source sets no provider'
      settings = Must.be_a(source[provider.to_s], Google::Protobuf::MessageExts)
      find(provider).from_proto(settings)
    end

    # Reads the nodes of every source.
    #
    # @param sources [Array<Proto::V1::InventorySource>] sources in order
    # @return [Array<Proto::V1::Node>] nodes in source order
    # @raise [DuplicateNode] when a node name appears twice
    # @raise [MissingProvider] when a source names no provider
    #: (Array[Proto::V1::InventorySource] sources) -> Array[Proto::V1::Node]
    def self.nodes(sources)
      origins = {} #: Hash[String, String]
      sources.flat_map do |source|
        provider = build(source)
        provider.nodes.each do |node|
          if (other = origins[node.name])
            raise DuplicateNode, "node #{node.name.inspect} is defined in both #{other} and #{provider.description}"
          end

          origins[node.name] = provider.description
        end
      end
    end
  end
end
