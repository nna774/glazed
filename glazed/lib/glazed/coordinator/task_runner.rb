# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/coordinator'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/runner'
require 'glazed/steps'
require 'glazed/workflow'

module Glazed
  class Coordinator
    # Performs {Proto::V1::CoordinatorTask}s for an external coordinator, such
    # as AWS Step Functions, which runs each step of a workflow as its own
    # call and passes the protobuf results between them. Node failures are
    # returned as {Proto::V1::StepFailure}s rather than raised, so the
    # coordinator carries them to the end of the batch.
    #
    # @example
    #   runner = Glazed::Coordinator::TaskRunner.new(coordinator:, workflows:, inventory: -> { Glazed::Sources.nodes(config.inventory.to_a) })
    #   batches = runner.perform(Glazed::Proto::V1::CoordinatorTask.new(prepare: {}))
    class TaskRunner
      # Cycles a coordinator execution runs when the task sets none.
      DEFAULT_MAX_CYCLES = 20 #: Integer

      #: type result = Proto::V1::Armed | Proto::V1::PreparedBatches | Proto::V1::NodeOutcome | Proto::V1::Batch

      # @param coordinator [Coordinator] changes the node schedules
      # @param workflows [Hash{String => Workflow}] the orchestrated workflows, by name
      # @param inventory [Proc] loads the current nodes
      # @param listener [Proc] receives events of the tasks and steps
      # @raise [ArgumentError] when the workflows differ from those the coordinator orchestrates
      #: (coordinator: Coordinator, workflows: Hash[String, Workflow], inventory: Orchestrator::inventory, ?listener: Runner::listener) -> void
      def initialize(coordinator:, workflows:, inventory:, listener: ->(_event) {})
        unless workflows.keys.sort == coordinator.workflows.sort
          raise ArgumentError, "workflows #{workflows.keys.sort} differ from the orchestrated #{coordinator.workflows.sort}"
        end

        @coordinator = coordinator #: Coordinator
        @workflows = workflows #: Hash[String, Workflow]
        @inventory = inventory #: Orchestrator::inventory
        @listener = listener #: Runner::listener
      end

      # @param task [Proto::V1::CoordinatorTask] the task
      # @return [Proto::V1::Armed, Proto::V1::PreparedBatches, Proto::V1::NodeOutcome, Proto::V1::Batch] its result
      # @raise [InvalidMessage] when the task breaks the rules of its schema
      # @raise [ArgumentError] when the task names an unknown workflow or step
      # @raise [Glazed::Error] when the inventory or the state backend fails
      #: (Proto::V1::CoordinatorTask task) -> TaskRunner::result
      def perform(task)
        Validation.validate!(task)
        if (check = task.check) then check(check)
        elsif task.prepare then prepare
        elsif (node_step = task.node_step) then node_step(node_step)
        elsif (batch_step = task.batch_step) then batch_step(batch_step)
        else complete(Must.because(task.complete) { 'validation requires a task' })
        end
      end

      # @param task [Proto::V1::CheckTask] the task
      # @return [Proto::V1::Armed] when to wake up, if at all
      #: (Proto::V1::CheckTask task) -> Proto::V1::Armed
      private def check(task)
        nodes = load_inventory.values
        @coordinator.sync_inventory(nodes)
        @coordinator.signal(task.signals.to_a, nodes:) unless task.signals.empty?
        wake = @coordinator.arm(
          token: task.token, cycle: task.cycle, max_cycles: task.max_cycles.zero? ? DEFAULT_MAX_CYCLES : task.max_cycles,
          grace: task.grace_seconds.zero? ? nil : task.grace_seconds,
        )
        Proto::V1::Armed.new(wait_until: wake && Google::Protobuf::Timestamp.from_time(wake))
      end

      # @return [Proto::V1::PreparedBatches] a batch of the due nodes of each workflow
      #: () -> Proto::V1::PreparedBatches
      private def prepare
        inventory = load_inventory
        @coordinator.sync_inventory(inventory.values)
        batches = @workflows.keys.to_h do |workflow|
          owner, names = @coordinator.claim(workflow)
          nodes = names.filter_map { inventory[it] }.map { Proto::V1::NodeOutcome.new(state: Proto::V1::NodeState.new(node: it)) }
          notify(level: 'info', workflow:, message: 'batch started', nodes: nodes.map { it.state&.node&.name.to_s }) unless nodes.empty?
          [workflow, Proto::V1::Batch.new(workflow:, owner:, nodes:)]
        end
        Proto::V1::PreparedBatches.new(batches:)
      end

      # @param task [Proto::V1::NodeStepTask] the task
      # @return [Proto::V1::NodeOutcome] the node's outcome after the step
      # @raise [ArgumentError] when the step is unknown or not a per-node step
      #: (Proto::V1::NodeStepTask task) -> Proto::V1::NodeOutcome
      private def node_step(task)
        step = step(task.workflow, task.step, Steps::NodeStep)
        outcome = Must.because(task.outcome) { 'validation requires outcome' }
        return outcome if outcome.failure

        state = Must.because(outcome.state) { 'validation requires state' }
        node = state.node&.name.to_s
        begin
          after = step.call(state)
        rescue StandardError => e
          # One unreachable or misbehaving device must not stop the others.
          notify(level: 'error', step: step.name, node:, error: e.class.name, message: e.message)
          return Proto::V1::NodeOutcome.new(state:, failure: Proto::V1::StepFailure.new(step: step.name, error: e.message))
        end
        notify(level: 'info', step: step.name, node:, changed: changed?(after, step), message: 'done')
        Proto::V1::NodeOutcome.new(state: after)
      end

      # @param task [Proto::V1::BatchStepTask] the task
      # @return [Proto::V1::Batch] the batch after the step
      # @raise [ArgumentError] when the step is unknown or not a batch step
      #: (Proto::V1::BatchStepTask task) -> Proto::V1::Batch
      private def batch_step(task)
        batch = Must.because(task.batch) { 'validation requires batch' }
        step = step(batch.workflow, task.step, Steps::BatchStep)
        return batch unless batch.error.empty?

        passing = batch.nodes.filter_map { it.state unless it.failure }
        begin
          after = step.call(Proto::V1::BatchState.new(nodes: passing)).nodes.to_h { [it.node&.name, it] }
        rescue StandardError => e
          notify(level: 'error', workflow: batch.workflow, step: step.name, error: e.class.name, message: e.message)
          return batch.dup.tap { it.error = "#{step.name}: #{e.message}" }
        end
        notify(level: 'info', workflow: batch.workflow, step: step.name, nodes: after.size, message: 'done')
        nodes = batch.nodes.map do |outcome|
          state = after[outcome.state&.node&.name]
          outcome.failure || state.nil? ? outcome : Proto::V1::NodeOutcome.new(state:)
        end
        Proto::V1::Batch.new(workflow: batch.workflow, owner: batch.owner, nodes:)
      end

      # @param task [Proto::V1::CompleteTask] the task
      # @return [Proto::V1::Batch] the batch, unchanged
      #: (Proto::V1::CompleteTask task) -> Proto::V1::Batch
      private def complete(task)
        batch = Must.because(task.batch) { 'validation requires batch' }
        names = batch.nodes.map { it.state&.node&.name.to_s }
        errors = {} #: Hash[String, String]
        batch.nodes.each do |outcome|
          failure = outcome.failure
          error = failure ? "#{failure.step}: #{failure.error}" : batch.error
          errors[outcome.state&.node&.name.to_s] = error unless error.empty?
        end
        @coordinator.complete(batch.workflow, owner: batch.owner, names:, errors:, nodes: load_inventory)
        notify(level: 'info', workflow: batch.workflow, message: 'batch finished', nodes: names.size, failed: errors.size)
        batch
      end

      # @return [Hash{String => Proto::V1::Node}] every node in the inventory, by name
      #: () -> Hash[String, Proto::V1::Node]
      private def load_inventory
        nodes = @inventory.call.to_h { [it.name, it] }
        notify(level: 'info', message: 'inventory loaded', nodes: nodes.size)
        nodes
      end

      # @param workflow [String] workflow name
      # @param name [String] step name
      # @param kind [Class] {Steps::NodeStep} or {Steps::BatchStep}
      # @return [Steps::Base] the step
      # @raise [ArgumentError] when the step is unknown or of another kind
      #: [S < Steps::Base] (String workflow, String name, Class[S] kind) -> S
      private def step(workflow, name, kind)
        steps = @workflows.fetch(workflow) { raise ArgumentError, "workflow #{workflow.inspect} is not orchestrated" }.steps
        found = steps.find { it.name == name } or raise ArgumentError, "workflow #{workflow.inspect} has no step #{name.inspect}"
        raise ArgumentError, "#{workflow}: #{name} is not a #{kind.name}" unless found.is_a?(kind)

        found
      end

      # @param state [Proto::V1::NodeState] state after the step
      # @param step [Steps::Base] the step
      # @return [Boolean] whether any artifact the step produced changed stored content
      #: (Proto::V1::NodeState state, Steps::Base step) -> bool
      private def changed?(state, step) = step.outputs.any? { state.artifacts[it]&.changed }

      # @param event [Hash{Symbol => String, Integer, Boolean, Array<String>, nil}] event fields
      # @return [void]
      #: (**Runner::event_value event) -> void
      private def notify(**event) = @listener.call(event)
    end
  end
end
