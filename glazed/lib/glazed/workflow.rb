# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/proto'
require 'glazed/steps'

module Glazed
  # Ordered, validated steps built from a {Proto::V1::Workflow}.
  #
  # @example
  #   context = Glazed::Steps::Context.from_proto(config.storages)
  #   workflow = Glazed::Workflow.from_proto(config.workflows.fetch('backup'), context:)
  class Workflow
    # Raised when steps are wired inconsistently.
    class Invalid < Glazed::Error; end

    # @param steps [Array<Steps::Base>] steps in order
    # @raise [Invalid] when there are no steps, step names repeat, an input is
    #   not produced by an earlier step, or an output is produced twice
    #: (steps: Array[Steps::Base]) -> void
    def initialize(steps:)
      @steps = steps.freeze #: Array[Steps::Base]
      validate
    end

    # Builds every step of a workflow definition.
    #
    # @param workflow [Proto::V1::Workflow] workflow definition
    # @param context [Steps::Context] named storages
    # @return [Workflow] the workflow
    # @raise [Invalid] when steps are wired inconsistently
    # @raise [Steps::InvalidStep] when a step definition is incomplete
    # @raise [Steps::Context::UnknownStorage] when a step names an unknown storage
    #: (Proto::V1::Workflow workflow, context: Steps::Context) -> Workflow
    def self.from_proto(workflow, context:)
      new(steps: workflow.steps.map { Steps.build(it, context:) })
    end

    # @return [Array<Steps::Base>] steps in order
    #: Array[Steps::Base]
    attr_reader :steps

    # @return [void]
    # @raise [Invalid] when steps are wired inconsistently
    #: () -> void
    private def validate
      raise Invalid, 'workflow has no steps' if steps.empty?

      names = steps.map(&:name)
      duplicated = names.select { names.count(it) > 1 }.uniq
      raise Invalid, "step names repeat: #{duplicated.join(', ')}" unless duplicated.empty?

      available = [] #: Array[String]
      steps.each do |step|
        missing = step.inputs - available
        raise Invalid, "#{step.name}: no earlier step produces #{missing.join(', ')}" unless missing.empty?

        repeated = step.outputs & available
        raise Invalid, "#{step.name}: #{repeated.join(', ')} is already produced" unless repeated.empty?

        available.concat(step.outputs)
      end
    end
  end
end
