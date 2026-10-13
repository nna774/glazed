# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/finder'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/steps/base'
require 'glazed/steps/context'

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

    # Builds the step a definition selects.
    #
    # @param step [Proto::V1::Step] step definition
    # @param context [Context] named storages the step refers to
    # @return [Base] the step
    # @raise [InvalidStep] when no action or name is set
    # @raise [Context::UnknownStorage] when the step names an unknown storage
    #: (Proto::V1::Step step, context: Context) -> Base
    def self.build(step, context:)
      raise InvalidStep, 'a step has no name' if step.name.empty?

      action = step.action or raise InvalidStep, "step #{step.name.inspect} sets no action"
      settings = Must.be_a(step[action.to_s], Google::Protobuf::MessageExts)
      find(action).from_proto(step.name, settings, context:)
    end
  end
end
