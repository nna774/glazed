# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/finder'
require 'glazed/must'
require 'glazed/plugin_registry'
require 'glazed/proto'
require 'glazed/step_context'
require 'glazed/steps/base'

module Glazed
  # Units of work in a workflow. Each takes and returns a protobuf state
  # ({Proto::V1::NodeState} or {Proto::V1::BatchState}), so a coordinator can
  # pass them between processes as ProtoJSON.
  module Steps
    # Raised when a step definition is incomplete.
    class InvalidStep < Glazed::Error; end

    # Finds a step class by snake_case name.
    #
    # @param name [String, Symbol] step kind, such as "fetch"
    # @return [Class<Base>] the step class
    # @raise [Finder::NotFound] when there is none, for example when the gem providing it is not installed
    # @raise [Must::Violation] when the name resolves to something other than a step
    #: (String | Symbol name) -> singleton(Base)
    def self.find(name)
      found = Finder.find(self, 'glazed/steps', name)
      return found if found.is_a?(Class) && found < Base && found != NodeStep && found != BatchStep

      raise Must::Violation, "#{found} is not a step"
    end

    # Steps implemented by plugins, by settings message type.
    PLUGINS = PluginRegistry.new('step') #: PluginRegistry

    # Registers a plugin step, selected by `plugin` steps whose settings are of the given type.
    #
    # @param settings_class [Class] generated message class of the step settings
    # @param implementation [Class<NodeStep>, Class<BatchStep>] step built with {Base.from_proto}
    # @return [void]
    #: (singleton(Google::Protobuf::AbstractMessage) settings_class, singleton(Base) implementation) -> void
    def self.register(settings_class, implementation)
      PLUGINS.register(settings_class, implementation)
    end

    # Builds the step a definition selects.
    #
    # @param step [Proto::V1::Step] step definition
    # @param context [StepContext] named storages the step refers to
    # @return [Base] the step
    # @raise [InvalidStep] when no action or name is set
    # @raise [StepContext::UnknownStorage] when the step names an unknown storage
    # @raise [PluginRegistry::UnknownPlugin] when no plugin is registered for the settings type
    #: (Proto::V1::Step step, context: StepContext) -> Base
    def self.build(step, context:)
      raise InvalidStep, 'a step has no name' if step.name.empty?

      action = step.action or raise InvalidStep, "step #{step.name.inspect} sets no action"
      if (packed = step.plugin)
        implementation, settings = PLUGINS.resolve(packed)
        return step_class(implementation).from_proto(step.name, settings, context:)
      end

      settings = Must.be_a(step[action.to_s], Google::Protobuf::MessageExts)
      find(action).from_proto(step.name, settings, context:)
    end

    # @param implementation [Module] registered implementation
    # @return [Class<Base>] the implementation as a step class
    # @raise [Must::Violation] when it is not a per-node or batch step
    #: (Module[untyped] implementation) -> singleton(Base)
    private_class_method def self.step_class(implementation)
      if implementation.is_a?(Class) && (implementation < NodeStep || implementation < BatchStep)
        return implementation
      end

      raise Must::Violation, "#{implementation} is not a step"
    end
  end
end
