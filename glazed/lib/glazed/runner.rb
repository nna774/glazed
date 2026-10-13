# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/proto'
require 'glazed/steps'
require 'glazed/workflow'

module Glazed
  # Runs a workflow in this process. Consecutive per-node steps run for each
  # node on a thread pool; a node whose step fails is reported and left out of
  # the rest of the workflow. Batch steps run with the remaining nodes, and
  # their failures propagate.
  #
  # @example
  #   result = Glazed::Runner.new(workflow:, jobs: 4).call(nodes)
  #   result.failures.each { warn "#{it.node.name}: #{it.error.message}" }
  class Runner
    #: type event_value = String | Integer | bool | nil
    #: type listener = ^(Hash[Symbol, Runner::event_value] event) -> void

    # A node that failed a step.
    class Failure
      # @param node [Proto::V1::Node] the node
      # @param step [String] name of the failed step
      # @param error [StandardError] the error
      #: (node: Proto::V1::Node, step: String, error: StandardError) -> void
      def initialize(node:, step:, error:)
        @node = node #: Proto::V1::Node
        @step = step #: String
        @error = error #: StandardError
      end

      # @return [Proto::V1::Node] the node
      #: Proto::V1::Node
      attr_reader :node
      # @return [String] name of the failed step
      #: String
      attr_reader :step
      # @return [StandardError] the error
      #: StandardError
      attr_reader :error
    end

    # Outcome of a run.
    class Result
      # @param states [Array<Proto::V1::NodeState>] states of the nodes that completed every step
      # @param failures [Array<Failure>] nodes that failed a step
      #: (states: Array[Proto::V1::NodeState], failures: Array[Failure]) -> void
      def initialize(states:, failures:)
        @states = states #: Array[Proto::V1::NodeState]
        @failures = failures #: Array[Failure]
      end

      # @return [Array<Proto::V1::NodeState>] states of the nodes that completed every step
      #: Array[Proto::V1::NodeState]
      attr_reader :states
      # @return [Array<Failure>] nodes that failed a step
      #: Array[Failure]
      attr_reader :failures

      # @return [Array<Proto::V1::NodeState>] states with at least one artifact whose write changed stored content
      #: () -> Array[Proto::V1::NodeState]
      def changed = states.select { |state| state.artifacts.values.any?(&:changed) }
    end

    # @param workflow [Workflow] the workflow
    # @param jobs [Integer] nodes processed in parallel
    # @param listener [Proc] receives an event hash per completed or failed step
    #: (workflow: Workflow, jobs: Integer, ?listener: Runner::listener) -> void
    def initialize(workflow:, jobs:, listener: ->(_event) {})
      @workflow = workflow #: Workflow
      @jobs = jobs #: Integer
      @listener = listener #: Runner::listener
      @lock = Mutex.new #: Thread::Mutex
    end

    # @param nodes [Array<Proto::V1::Node>] nodes to run against
    # @return [Result] the outcome
    # @raise [Glazed::Error] when a batch step fails
    #: (Array[Proto::V1::Node] nodes) -> Result
    def call(nodes)
      states = nodes.map { Proto::V1::NodeState.new(node: it) }
      failures = [] #: Array[Failure]
      @workflow.steps.chunk_while { |a, b| a.is_a?(Steps::NodeStep) && b.is_a?(Steps::NodeStep) }.each do |chunk|
        first = chunk.first
        states = case first
                 when Steps::BatchStep then run_batch(first, states)
                 else run_per_node(chunk.grep(Steps::NodeStep), states, failures)
                 end
      end
      Result.new(states:, failures:)
    end

    # @param step [Steps::BatchStep] the step
    # @param states [Array<Proto::V1::NodeState>] node states
    # @return [Array<Proto::V1::NodeState>] node states after the step
    #: (Steps::BatchStep step, Array[Proto::V1::NodeState] states) -> Array[Proto::V1::NodeState]
    private def run_batch(step, states)
      batch = step.call(Proto::V1::BatchState.new(nodes: states))
      after = batch.nodes.to_a
      if step.outputs.empty?
        notify(level: 'info', step: step.name, nodes: after.size, message: 'done')
      else
        notify(level: 'info', step: step.name, nodes: after.size, changed: after.count { changed?(it, step) }, message: 'done')
      end
      after
    end

    # @param steps [Array<Steps::NodeStep>] consecutive per-node steps
    # @param states [Array<Proto::V1::NodeState>] node states
    # @param failures [Array<Failure>] collects failed nodes
    # @return [Array<Proto::V1::NodeState>] states of the nodes that completed the steps, in input order
    #: (Array[Steps::NodeStep] steps, Array[Proto::V1::NodeState] states, Array[Failure] failures) -> Array[Proto::V1::NodeState]
    private def run_per_node(steps, states, failures)
      queue = Thread::Queue.new(states.each_with_index.to_a)
      queue.close
      results = {} #: Hash[Integer, Proto::V1::NodeState]
      workers = Array.new([@jobs, states.size].min) do
        Thread.new do
          while (item = queue.pop)
            state, index = item
            result = run_node(steps, state, failures)
            @lock.synchronize { results[index] = result } if result
          end
        end
      end
      workers.each(&:join)
      results.sort.map { |_, state| state }
    end

    # @param steps [Array<Steps::NodeStep>] consecutive per-node steps
    # @param state [Proto::V1::NodeState] the node's state
    # @param failures [Array<Failure>] collects the node when it fails
    # @return [Proto::V1::NodeState, nil] the final state, or nil when a step failed
    #: (Array[Steps::NodeStep] steps, Proto::V1::NodeState state, Array[Failure] failures) -> Proto::V1::NodeState?
    private def run_node(steps, state, failures)
      node = state.node or raise ArgumentError, 'node state has no node'
      steps.inject(state) do |current, step|
        begin
          current = step.call(current)
        rescue StandardError => e
          # One unreachable or misbehaving device must not stop the others.
          @lock.synchronize { failures << Failure.new(node:, step: step.name, error: e) }
          notify(level: 'error', step: step.name, node: node.name, error: e.class.name, message: e.message)
          return nil
        end
        notify(level: 'info', step: step.name, node: node.name, changed: changed?(current, step), message: 'done')
        current
      end
    end

    # @param state [Proto::V1::NodeState] state after the step
    # @param step [Steps::Base] the step
    # @return [Boolean] whether any artifact the step produced changed stored content
    #: (Proto::V1::NodeState state, Steps::Base step) -> bool
    private def changed?(state, step) = step.outputs.any? { state.artifacts[it]&.changed }

    # @param event [Hash{Symbol => String, Integer, Boolean, nil}] event fields
    # @return [void]
    #: (**Runner::event_value event) -> void
    private def notify(**event)
      @lock.synchronize { @listener.call(event) }
    end
  end
end
