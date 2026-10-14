# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'glazed'
require 'glazed/finder'
require 'glazed/must'
require 'glazed/plugin_registry'

module Glazed
  # Secret sources other than a value, an environment variable or a file:
  # those built for a message field of {Proto::V1::SecretRef}, such as
  # `command` or glazed-aws's `ssm`, and plugins used by `plugin` references.
  module Secrets
    # A plugin source of one secret value, built from its settings message.
    class Base
      # Builds the source from its settings message.
      #
      # @param settings [Google::Protobuf::MessageExts] settings unpacked from the reference
      # @return [Base] the source
      #: (Google::Protobuf::MessageExts settings) -> Base
      def self.from_proto(settings) = raise NotImplementedError

      # Reads the secret, each time it is used. A source that fetches the
      # value remotely may keep it for a while; the {SecretsResolver} holding
      # the source bounds how long.
      #
      # @return [String] the secret value
      #: () -> String
      def value = raise NotImplementedError
    end

    # Finds a secret source class by snake_case name.
    #
    # @param name [String, Symbol] source name, such as "ssm"
    # @return [Class<Base>] the source class
    # @raise [Finder::NotFound] when there is none, for example when the gem providing it is not installed
    # @raise [Must::Violation] when the name resolves to something other than a secret source
    #: (String | Symbol name) -> singleton(Base)
    def self.find(name) = source_class(Finder.find(self, 'glazed/secrets', name))

    # Secret sources implemented by plugins, by settings message type.
    PLUGINS = PluginRegistry.new('secret source') #: PluginRegistry

    # Registers a plugin secret source, selected by `plugin` references whose
    # settings are of the given type.
    #
    # @param settings_class [Class] generated message class of the source settings
    # @param implementation [Class<Base>] source built with {Base.from_proto}
    # @return [void]
    # @example
    #   Glazed::Secrets.register(GlazedVault::V1::VaultSecret, GlazedVault::Secret)
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
      source_class(implementation).from_proto(settings)
    end

    # @param implementation [Module] registered or found implementation
    # @return [Class<Base>] the implementation as a secret source class
    # @raise [Must::Violation] when it is not a secret source
    #: (Module[untyped] implementation) -> singleton(Base)
    private_class_method def self.source_class(implementation)
      return implementation if implementation.is_a?(Class) && implementation < Base

      raise Must::Violation, "#{implementation} is not a secret source"
    end
  end
end
