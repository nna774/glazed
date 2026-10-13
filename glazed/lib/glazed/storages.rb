# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/finder'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/storages/base'

module Glazed
  # Namespace of storage implementations, looked up by name.
  module Storages
    # Raised when a storage config names no backend.
    class MissingBackend < Glazed::Error; end

    # Finds a storage class by snake_case name.
    #
    # @param name [String, Symbol] storage name, such as "git"
    # @return [Class<Base>] the storage class
    # @raise [Finder::NotFound] when there is none, for example when the gem providing it is not installed
    # @raise [Must::Violation] when the name resolves to something other than a storage
    #: (String | Symbol name) -> singleton(Base)
    def self.find(name)
      found = Finder.find(self, 'glazed/storages', name)
      return found if found.is_a?(Class) && found < Base

      raise Must::Violation, "#{found} is not a storage"
    end

    # Builds the storage a config selects.
    #
    # @param config [Proto::V1::StorageConfig] storage settings
    # @return [Base] the storage
    # @raise [MissingBackend] when no backend is set
    # @raise [Finder::NotFound] when the backend is not available
    #: (Proto::V1::StorageConfig config) -> Base
    def self.build(config)
      backend = config.backend or raise MissingBackend, 'storage config sets no backend'
      settings = Must.be_a(config[backend.to_s], Google::Protobuf::MessageExts)
      find(backend).from_proto(settings)
    end

    # Storage key of a node, "group/name" or just "name" without a group.
    #
    # @param node [Proto::V1::Node] the node
    # @return [String] the key
    #: (Proto::V1::Node node) -> String
    def self.key_for(node)
      node.group.empty? ? node.name : "#{node.group}/#{node.name}"
    end
  end
end
