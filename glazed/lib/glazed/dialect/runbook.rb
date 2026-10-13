# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/command_result'
require 'glazed/dialect'
require 'glazed/dialect/actions'
require 'glazed/dialect/run'

module Glazed
  module Dialect
    # Ordered steps that collect configuration from a node.
    class Runbook
      #: type step_block = ^(Run run) -> void

      # One step of a runbook.
      class Step
        # @param description [String] what the step does, such as its command line
        # @param block [Proc] called with the run
        #: (description: String, block: Runbook::step_block) -> void
        def initialize(description:, block:)
          @description = description #: String
          @block = block #: Runbook::step_block
        end

        # @return [String] what the step does
        #: String
        attr_reader :description
        # @return [Proc] called with the run
        #: Runbook::step_block
        attr_reader :block
      end

      # Collects steps for a runbook.
      #
      # @example
      #   builder.command('show version') { |result| comment(result.output) }
      #   builder.raw { |run| run.vars[:model] = run.command('show model').output }
      class Builder
        #: () -> void
        def initialize
          @steps = [] #: Array[Step]
        end

        # Adds a step that runs a command and emits what the block returns, or
        # the output itself without a block.
        #
        # @param line [String] command line
        # @yieldparam result [CommandResult] filtered command result
        # @yieldreturn [Actions::Append, Actions::Replace, Actions::Multi, String, nil] action to emit
        # @return [void]
        #: (String line) ?{ (CommandResult result) -> Actions::action? } -> void
        def command(line, &callback)
          raw(line) do |run|
            result = run.command(line)
            run.emit(callback ? callback.call(result) : result.output)
          end
        end

        # Adds a step that drives the run directly.
        #
        # @param description [String] what the step does
        # @yieldparam run [Run] the run in progress
        # @return [void]
        #: (?String description) { (Run run) -> void } -> void
        def raw(description = '', &block)
          @steps << Step.new(description:, block:)
        end

        # @return [Runbook] runbook of the collected steps
        #: () -> Runbook
        def build = Runbook.new(steps: @steps.dup)
      end

      # @param steps [Array<Step>] steps in order
      #: (steps: Array[Step]) -> void
      def initialize(steps:)
        @steps = steps.freeze #: Array[Step]
      end

      # @return [Array<Step>] steps in order
      #: Array[Step]
      attr_reader :steps

      # Runs every step.
      #
      # @param run [Run] run to execute against
      # @return [String] the collected configuration
      #: (Run run) -> String
      def execute(run)
        steps.each { it.block.call(run) }
        run.output
      end
    end
  end
end
