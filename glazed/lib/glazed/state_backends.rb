# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/finder'
require 'glazed/must'
require 'glazed/plugin_registry'
require 'glazed/proto'
require 'glazed/state_backends/base'
require 'glazed/step_context'
require 'glazed/validation'

module Glazed
  # Namespace of state backend implementations, looked up by name.
  module StateBackends
    # Raised when a state backend config names no backend.
    class MissingBackend < Glazed::Error; end

    # Finds a state backend class by snake_case name.
    #
    # @param name [String, Symbol] state backend name, such as "sqlite"
    # @return [Class<Base>] the state backend class
    # @raise [Finder::NotFound] when there is none, for example when the gem providing it is not installed
    # @raise [Must::Violation] when the name resolves to something other than a state backend
    #: (String | Symbol name) -> singleton(Base)
    def self.find(name) = state_backend_class(Finder.find(self, 'glazed/state_backends', name))

    # State backends implemented by plugins, by settings message type.
    PLUGINS = PluginRegistry.new('state backend') #: PluginRegistry

    # Registers a plugin state backend, selected by `plugin` configs whose
    # settings are of the given type.
    #
    # @param settings_class [Class] generated message class of the state backend settings
    # @param implementation [Class<Base>] state backend built with {Base.from_proto}
    # @return [void]
    #: (singleton(Google::Protobuf::AbstractMessage) settings_class, singleton(Base) implementation) -> void
    def self.register(settings_class, implementation)
      PLUGINS.register(settings_class, implementation)
    end

    # Builds the state backend a config selects.
    #
    # @param config [Proto::V1::StateBackendConfig] state backend settings
    # @param context [StepContext] configured storages, and where progress is reported
    # @return [Base] the state backend
    # @raise [InvalidMessage] when the config breaks the rules of its schema
    # @raise [Finder::NotFound] when the backend is not available
    # @raise [PluginRegistry::UnknownPlugin] when no plugin is registered for the settings type
    #: (Proto::V1::StateBackendConfig config, context: StepContext) -> Base
    def self.build(config, context:)
      Validation.validate!(config)
      backend = config.backend or raise MissingBackend, 'state backend config sets no backend'
      if (packed = config.plugin)
        implementation, settings = PLUGINS.resolve(packed)
        return state_backend_class(implementation).from_proto(settings, context:)
      end

      settings = Must.be_a(config[backend.to_s], Google::Protobuf::MessageExts)
      find(backend).from_proto(settings, context:)
    end

    # @param implementation [Module] registered or found implementation
    # @return [Class<Base>] the implementation as a state backend class
    # @raise [Must::Violation] when it is not a state backend
    #: (Module[untyped] implementation) -> singleton(Base)
    private_class_method def self.state_backend_class(implementation)
      return implementation if implementation.is_a?(Class) && implementation < Base

      raise Must::Violation, "#{implementation} is not a state backend"
    end
  end
end
