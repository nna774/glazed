# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'securerandom'
require 'socket'
require 'glazed'
require 'glazed/must'
require 'glazed/orchestrator/policy'
require 'glazed/proto'
require 'glazed/runner'
require 'glazed/state_backends/base'

module Glazed
  # Changes node schedules in a state backend as the orchestrated workflows
  # run: follows the inventory, applies signals, leases due nodes and records
  # the outcome of their runs. {Orchestrator} drives it in one process; an
  # external coordinator such as AWS Step Functions drives it one call at a time.
  #
  # @example
  #   coordinator = Glazed::Coordinator.new(settings: config.orchestrator, backend:)
  #   coordinator.sync_inventory(nodes.map(&:name))
  #   owner, names = coordinator.claim('backup')
  #   coordinator.complete('backup', owner:, names:, errors: {})
  class Coordinator
    # Seconds a lease lasts when the settings set none.
    DEFAULT_LEASE = 3600 #: Integer

    # @param settings [Proto::V1::Orchestrator] orchestrator settings
    # @param backend [StateBackends::Base] where schedules are kept
    # @param listener [Proc] receives events of schedule changes
    # @param clock [Proc] returns the current time
    # @param random [Random] source of jitter
    # @param owner [String] identifies this process in leases
    #: (settings: Proto::V1::Orchestrator, backend: StateBackends::Base, ?listener: Runner::listener, ?clock: ^() -> Time, ?random: Random, ?owner: String) -> void
    def initialize(settings:, backend:, listener: ->(_event) {}, clock: -> { Time.now }, random: Random.new,
                   owner: "#{Socket.gethostname}:#{Process.pid}:#{SecureRandom.hex(4)}")
      @settings = settings #: Proto::V1::Orchestrator
      @backend = backend #: StateBackends::Base
      @listener = listener #: Runner::listener
      @clock = clock #: ^() -> Time
      @random = random #: Random
      @owner = owner #: String
    end

    # @return [Proto::V1::Orchestrator] orchestrator settings
    #: Proto::V1::Orchestrator
    attr_reader :settings
    # @return [StateBackends::Base] where schedules are kept
    #: StateBackends::Base
    attr_reader :backend
    # @return [String] identifies this process in leases
    #: String
    attr_reader :owner

    # @return [Array<String>] names of the orchestrated workflows
    #: () -> Array[String]
    def workflows = @settings.workflows.keys

    # @param workflow [String] workflow name
    # @return [Proto::V1::Orchestration] how the workflow is orchestrated
    # @raise [ArgumentError] when the workflow is not orchestrated
    #: (String workflow) -> Proto::V1::Orchestration
    def orchestration(workflow)
      @settings.workflows[workflow] or raise ArgumentError, "workflow #{workflow.inspect} is not orchestrated"
    end

    # Adds records for nodes new to the inventory, due within the schedule's
    # jitter, and deletes those of nodes gone, in every workflow.
    #
    # @param nodes [Array<String>] names of every node in the inventory
    # @return [void]
    #: (Array[String] nodes) -> void
    def sync_inventory(nodes)
      now = @clock.call
      workflows.each do |workflow|
        known = @backend.list(workflow).map(&:node)
        added = nodes - known
        removed = known - nodes
        next if added.empty? && removed.empty?

        schedule = orchestration(workflow).schedule
        @backend.update_all(workflow, added + removed) do |node, record|
          next nil if removed.include?(node)

          record || Orchestrator::Policy.discovered(workflow, node, now:, schedule:, random: @random)
        end
        notify(level: 'info', workflow:, message: 'inventory changed', nodes: nodes.size, added:, removed:)
      end
    end

    # Applies signals with each workflow's debounce, one change per workflow.
    # Signals naming a node or workflow unknown here are reported and skipped.
    #
    # @param signals [Array<Proto::V1::Signal>] the signals
    # @param nodes [Array<String>] names of every node in the inventory, which all_nodes signals stand for
    # @return [Hash{String => Hash{String => Proto::V1::NodeSchedule}}] the resulting records, by workflow and node name
    #: (Array[Proto::V1::Signal] signals, nodes: Array[String]) -> Hash[String, Hash[String, Proto::V1::NodeSchedule]]
    def signal(signals, nodes:)
      now = @clock.call
      pending = {} #: Hash[String, Hash[String, Array[Proto::V1::Signal]]]
      signals.each do |signal|
        targets = signal.all_nodes ? nodes : [signal.node]
        unknown_nodes = targets - nodes
        targets -= unknown_nodes
        notify(level: 'warn', message: 'signal for unknown nodes skipped', source: signal.source, nodes: unknown_nodes) unless unknown_nodes.empty?

        chosen = signal.workflows.empty? ? workflows : signal.workflows.to_a
        unknown_workflows = chosen - workflows
        unless unknown_workflows.empty?
          notify(level: 'warn', message: 'signal for workflows not orchestrated skipped', source: signal.source, workflows: unknown_workflows)
        end

        (chosen - unknown_workflows).product(targets).each do |workflow, node|
          ((pending[workflow] ||= {})[node] ||= []) << for_node(signal, node)
        end
      end

      pending.to_h do |workflow, by_node|
        debounce = orchestration(workflow).debounce
        records = @backend.update_all(workflow, by_node.keys) do |node, record|
          by_node.fetch(node).inject(record) { |current, signal| Orchestrator::Policy.signal(current, signal, workflow:, now:, debounce:) }
        end
        [workflow, records]
      end
    end

    # Leases due nodes of a workflow, at most the workflow's batch size.
    #
    # @param workflow [String] workflow name
    # @return [Array(String, Array<String>)] identifier of the batch, and names of the leased nodes
    #: (String workflow) -> [String, Array[String]]
    def claim(workflow)
      now = @clock.call
      owner = "#{@owner}:#{SecureRandom.hex(4)}"
      settings = orchestration(workflow)
      limit = settings.batch_size.zero? ? nil : settings.batch_size
      due = @backend.list_due(workflow, now:, limit:)
      return [owner, []] if due.empty?

      lease_seconds = settings.lease_seconds.zero? ? DEFAULT_LEASE : settings.lease_seconds
      records = @backend.update_all(workflow, due.map(&:node)) do |_node, record|
        Orchestrator::Policy.claim(record, owner:, now:, lease_seconds:)
      end
      [owner, records.values.select { it.lease_owner == owner }.map(&:node)]
    end

    # Records the outcome of a batch and schedules each node's next run.
    # Records leased to another batch, and records deleted meanwhile, stay as they are.
    #
    # @param workflow [String] workflow name
    # @param owner [String] identifier of the batch
    # @param names [Array<String>] names of the nodes the batch ran
    # @param errors [Hash{String => String}] why nodes failed, by node name
    # @return [void]
    #: (String workflow, owner: String, names: Array[String], errors: Hash[String, String]) -> void
    def complete(workflow, owner:, names:, errors:)
      finished_at = @clock.call
      schedule = orchestration(workflow).schedule
      @backend.update_all(workflow, names) do |node, record|
        Orchestrator::Policy.completed(record, owner:, finished_at:, error: errors[node], schedule:, random: @random)
      end
    end

    # Gives up leases without recording a run, so the nodes run again soon.
    #
    # @param workflow [String] workflow name
    # @param owner [String] identifier of the batch
    # @param names [Array<String>] names of the leased nodes
    # @return [void]
    #: (String workflow, owner: String, names: Array[String]) -> void
    def release(workflow, owner:, names:)
      @backend.update_all(workflow, names) { |_node, record| Orchestrator::Policy.released(record, owner:) }
    end

    # The earliest time a node of any workflow may be claimed: its due date,
    # or the end of its lease while another batch holds it.
    #
    # @return [Time, nil] the time; nil when there are no records
    #: () -> Time?
    def next_due
      now = @clock.call
      times = workflows.flat_map do |workflow|
        @backend.list(workflow).filter_map do |record|
          Orchestrator::Policy.time(Orchestrator::Policy.running?(record, now) ? record.lease_until : record.due_at)
        end
      end
      times.min
    end

    # @param signal [Proto::V1::Signal] a signal for one node or every node
    # @param node [String] node name
    # @return [Proto::V1::Signal] the signal for that node alone
    #: (Proto::V1::Signal signal, String node) -> Proto::V1::Signal
    private def for_node(signal, node)
      return signal unless signal.all_nodes

      signal.dup.tap do |copy|
        copy.node = node
        copy.all_nodes = false
      end
    end

    # @param event [Hash{Symbol => String, Integer, Boolean, Array<String>, nil}] event fields
    # @return [void]
    #: (**Runner::event_value event) -> void
    private def notify(**event) = @listener.call(event)
  end
end
