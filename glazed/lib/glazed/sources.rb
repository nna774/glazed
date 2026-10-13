# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/finder'
require 'glazed/must'
require 'glazed/plugin_registry'
require 'glazed/proto'
require 'glazed/sources/base'
require 'glazed/validation'

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

    # Inventory providers implemented by plugins, by settings message type.
    PLUGINS = PluginRegistry.new('inventory provider') #: PluginRegistry

    # Registers a plugin provider, selected by `plugin` sources whose settings are of the given type.
    #
    # @param settings_class [Class] generated message class of the provider settings
    # @param implementation [Class<Base>] provider built with {Base.from_proto}
    # @return [void]
    # @example
    #   Glazed::Sources.register(GlazedNetbox::V1::NetboxInventory, GlazedNetbox::Source)
    #: (singleton(Google::Protobuf::AbstractMessage) settings_class, singleton(Base) implementation) -> void
    def self.register(settings_class, implementation)
      PLUGINS.register(settings_class, implementation)
    end

    # Builds the provider a source selects.
    #
    # @param source [Proto::V1::InventorySource] provider settings
    # @return [Base] the provider
    # @raise [InvalidMessage] when the source breaks the rules of its schema
    # @raise [Finder::NotFound] when the provider is not available
    # @raise [PluginRegistry::UnknownPlugin] when no plugin is registered for the settings type
    #: (Proto::V1::InventorySource source) -> Base
    def self.build(source)
      Validation.validate!(source)
      provider = source.provider or raise MissingProvider, 'inventory source sets no provider'
      if (packed = source.plugin)
        implementation, settings = PLUGINS.resolve(packed)
        return provider_class(implementation).from_proto(settings)
      end

      settings = Must.be_a(source[provider.to_s], Google::Protobuf::MessageExts)
      find(provider).from_proto(settings)
    end

    # @param implementation [Module] registered implementation
    # @return [Class<Base>] the implementation as a provider class
    # @raise [Must::Violation] when it is not a provider
    #: (Module[untyped] implementation) -> singleton(Base)
    private_class_method def self.provider_class(implementation)
      return implementation if implementation.is_a?(Class) && implementation < Base

      raise Must::Violation, "#{implementation} is not an inventory provider"
    end

    # Reads the nodes of every source.
    #
    # @param sources [Array<Proto::V1::InventorySource>] sources in order
    # @return [Array<Proto::V1::Node>] nodes in source order
    # @raise [DuplicateNode] when a node name appears twice
    # @raise [Base::InvalidInventory] when a node lacks a name or dialect
    # @raise [InvalidMessage] when a source breaks the rules of its schema
    #: (Array[Proto::V1::InventorySource] sources) -> Array[Proto::V1::Node]
    def self.nodes(sources)
      origins = {} #: Hash[String, String]
      sources.flat_map do |source|
        provider = build(source)
        provider.nodes.each do |node|
          raise Base::InvalidInventory, "#{provider.description}: a node has no name" if node.name.empty?
          raise Base::InvalidInventory, "#{provider.description}: node #{node.name.inspect} has no dialect" if node.dialect.empty?
          if (other = origins[node.name])
            raise DuplicateNode, "node #{node.name.inspect} is defined in both #{other} and #{provider.description}"
          end

          origins[node.name] = provider.description
        end
      end
    end
  end
end
