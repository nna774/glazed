# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'google/protobuf/well_known_types'
require 'glazed'
require 'glazed/validation'

module Glazed
  # Implementations of one kind of plugin, keyed by the full name of the
  # settings message a config packs into a google.protobuf.Any.
  #
  # @example A plugin gem registering an inventory provider
  #   Glazed::Sources.register(GlazedNetbox::V1::NetboxInventory, GlazedNetbox::Source)
  class PluginRegistry
    # Raised when no implementation is registered for a settings type.
    class UnknownPlugin < Glazed::Error; end

    # @param kind [String] what the plugins implement, for error messages
    #: (String kind) -> void
    def initialize(kind)
      @kind = kind #: String
      @implementations = {} #: Hash[String, Module[untyped]]
      @lock = Mutex.new #: Thread::Mutex
    end

    # Registers the implementation for a settings message type.
    #
    # @param settings_class [Class] generated message class of the settings
    # @param implementation [Module] implementation built from those settings
    # @return [void]
    #: (singleton(Google::Protobuf::AbstractMessage) settings_class, Module[untyped] implementation) -> void
    def register(settings_class, implementation)
      @lock.synchronize { @implementations[settings_class.descriptor.name] = implementation }
    end

    # Removes the implementation for a settings message type.
    #
    # @param settings_class [Class] generated message class of the settings
    # @return [void]
    #: (singleton(Google::Protobuf::AbstractMessage) settings_class) -> void
    def unregister(settings_class)
      @lock.synchronize { @implementations.delete(settings_class.descriptor.name) }
    end

    # Finds the implementation for packed settings and unpacks them.
    #
    # @param any [Google::Protobuf::Any] packed settings
    # @return [Array(Module, Google::Protobuf::MessageExts)] the implementation and the settings message
    # @raise [UnknownPlugin] when no implementation is registered for the settings type
    # @raise [InvalidMessage] when the settings break the rules of their schema
    #: (Google::Protobuf::Any any) -> [Module[untyped], Google::Protobuf::MessageExts]
    def resolve(any)
      type = any.type_name.to_s
      implementation = @lock.synchronize { @implementations[type] }
      unless implementation
        raise UnknownPlugin, "no #{@kind} plugin is registered for #{type}; require the gem providing it with `requires`"
      end

      settings_class = Google::Protobuf::DescriptorPool.generated_pool.lookup(type)&.msgclass
      settings = settings_class && any.unpack(settings_class)
      raise UnknownPlugin, "cannot unpack #{type} settings" unless settings.is_a?(Google::Protobuf::MessageExts)

      Validation.validate!(settings, origin: type)
      [implementation, settings]
    end
  end
end
