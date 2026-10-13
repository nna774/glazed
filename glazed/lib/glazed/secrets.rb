# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'glazed'
require 'glazed/must'
require 'glazed/plugin_registry'

module Glazed
  # Secret sources implemented by plugins, used by `plugin` secret references.
  module Secrets
    # A plugin source of one secret value, built from its settings message.
    class Base
      # Builds the source from its settings message.
      #
      # @param settings [Google::Protobuf::MessageExts] settings unpacked from the reference
      # @return [Base] the source
      #: (Google::Protobuf::MessageExts settings) -> Base
      def self.from_proto(settings) = raise NotImplementedError

      # Reads the secret, each time it is used.
      #
      # @return [String] the secret value
      #: () -> String
      def value = raise NotImplementedError
    end

    # Secret sources implemented by plugins, by settings message type.
    PLUGINS = PluginRegistry.new('secret source') #: PluginRegistry

    # Registers a plugin secret source, selected by `plugin` references whose
    # settings are of the given type.
    #
    # @param settings_class [Class] generated message class of the source settings
    # @param implementation [Class<Base>] source built with {Base.from_proto}
    # @return [void]
    # @example
    #   Glazed::Secrets.register(GlazedAws::V1::SsmParameter, GlazedAws::SsmParameterSecret)
    #: (singleton(Google::Protobuf::AbstractMessage) settings_class, singleton(Base) implementation) -> void
    def self.register(settings_class, implementation)
      PLUGINS.register(settings_class, implementation)
    end

    # Builds the source for packed settings.
    #
    # @param packed [Google::Protobuf::Any] settings from a secret reference
    # @return [Base] the source
    # @raise [PluginRegistry::UnknownPlugin] when no plugin is registered for the settings type
    #: (Google::Protobuf::Any packed) -> Base
    def self.build(packed)
      implementation, settings = PLUGINS.resolve(packed)
      raise Must::Violation, "#{implementation} is not a secret source" unless implementation.is_a?(Class) && implementation < Base

      implementation.from_proto(settings)
    end
  end
end
