# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/finder'
require 'glazed/must'
require 'glazed/plugin_registry'
require 'glazed/proto'
require 'glazed/storage_context'
require 'glazed/storages/base'
require 'glazed/validation'

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

    # Storages implemented by plugins, by settings message type.
    PLUGINS = PluginRegistry.new('storage') #: PluginRegistry

    # Registers a plugin storage, selected by `plugin` configs whose settings
    # are of the given type. Its pointers carry their own location message in
    # the `plugin` case of {Proto::V1::Pointer}.
    #
    # @param settings_class [Class] generated message class of the storage settings
    # @param implementation [Class<Base>] storage built with {Base.from_proto}
    # @return [void]
    #: (singleton(Google::Protobuf::AbstractMessage) settings_class, singleton(Base) implementation) -> void
    def self.register(settings_class, implementation)
      PLUGINS.register(settings_class, implementation)
    end

    # Builds the storage a config selects.
    #
    # @param config [Proto::V1::StorageConfig] storage settings
    # @param context [StorageContext] secrets the settings refer to
    # @return [Base] the storage
    # @raise [InvalidMessage] when the config breaks the rules of its schema
    # @raise [Finder::NotFound] when the backend is not available
    # @raise [PluginRegistry::UnknownPlugin] when no plugin is registered for the settings type
    #: (Proto::V1::StorageConfig config, ?context: StorageContext) -> Base
    def self.build(config, context: StorageContext.new)
      Validation.validate!(config)
      backend = config.backend or raise MissingBackend, 'storage config sets no backend'
      if (packed = config.plugin)
        implementation, settings = PLUGINS.resolve(packed)
        return storage_class(implementation).from_proto(settings, context:)
      end

      settings = Must.be_a(config[backend.to_s], Google::Protobuf::MessageExts)
      find(backend).from_proto(settings, context:)
    end

    # @param implementation [Module] registered implementation
    # @return [Class<Base>] the implementation as a storage class
    # @raise [Must::Violation] when it is not a storage
    #: (Module[untyped] implementation) -> singleton(Base)
    private_class_method def self.storage_class(implementation)
      return implementation if implementation.is_a?(Class) && implementation < Base

      raise Must::Violation, "#{implementation} is not a storage"
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
