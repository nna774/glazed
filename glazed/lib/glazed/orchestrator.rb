# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/coordinator'
require 'glazed/orchestrator/policy'
require 'glazed/proto'
require 'glazed/runner'
require 'glazed/state_backends/base'
require 'glazed/workflow'

module Glazed
  # Runs workflows for nodes as they become due, until stopped. Due dates
  # live in a state backend, per workflow and node: nodes new to the inventory
  # are due right away, signals move a node's due date per
  # {Proto::V1::Debounce}, and each run schedules the next per
  # {Proto::V1::Schedule}. Due nodes of a workflow are leased and run together
  # as one batch, so batch steps such as publish see all of them. Workflows
  # take turns, running one batch at a time.
  #
  # @example
  #   orchestrator = Glazed::Orchestrator.new(settings:, workflows: {'backup' => workflow}, backend:, inventory: -> { nodes }, jobs: 4)
  #   trap('TERM') { orchestrator.stop }
  #   orchestrator.run
  class Orchestrator
    # Seconds between checks for due nodes when the settings set none.
    DEFAULT_POLL = 30 #: Integer
    # Seconds between inventory reloads when the settings set none.
    DEFAULT_INVENTORY_REFRESH = 300 #: Integer
    # Byte written to the wakeup pipe by {#stop}.
    STOP = 's' #: String
    # Byte written to the wakeup pipe by {#reload_inventory}.
    RELOAD_INVENTORY = 'i' #: String

    #: type inventory = ^() -> Array[Proto::V1::Node]

    # Applies signals to the nodes' schedules in one change.
    #
    # @param backend [StateBackends::Base] where schedules are kept
    # @param workflow [String] workflow name
    # @param signals [Array<Proto::V1::Signal>] the signals
    # @param debounce [Proto::V1::Debounce, nil] the debounce settings
    # @param now [Time] current time, used for signals without a reception time
    # @return [Hash{String => Proto::V1::NodeSchedule}] the resulting records, by node name
    #: (backend: StateBackends::Base, workflow: String, signals: Array[Proto::V1::Signal], debounce: Proto::V1::Debounce?, ?now: Time) -> Hash[String, Proto::V1::NodeSchedule]
    def self.signal(backend:, workflow:, signals:, debounce:, now: Time.now)
      by_node = signals.group_by(&:node)
      backend.update_all(workflow, by_node.keys) do |node, record|
        by_node.fetch(node).inject(record) { |current, signal| Policy.signal(current, signal, workflow:, now:, debounce:) }
      end
    end

    # @param settings [Proto::V1::Orchestrator] orchestrator settings
    # @param workflows [Hash{String => Workflow}] the workflows the settings orchestrate, by name
    # @param backend [StateBackends::Base] where schedules are kept
    # @param inventory [Proc] loads the current nodes
    # @param jobs [Integer] nodes processed in parallel
    # @param listener [Proc] receives events of the orchestrator and the runs
    # @param clock [Proc] returns the current time
    # @param random [Random] source of jitter
    # @raise [ArgumentError] when the workflows differ from those the settings orchestrate
    #: (settings: Proto::V1::Orchestrator, workflows: Hash[String, Workflow], backend: StateBackends::Base, inventory: Orchestrator::inventory, jobs: Integer, ?listener: Runner::listener, ?clock: ^() -> Time, ?random: Random) -> void
    def initialize(settings:, workflows:, backend:, inventory:, jobs:, listener: ->(_event) {}, clock: -> { Time.now }, random: Random.new)
      unless workflows.keys.sort == settings.workflows.keys.sort
        raise ArgumentError, "workflows #{workflows.keys.sort} differ from the orchestrated #{settings.workflows.keys.sort}"
      end

      @settings = settings #: Proto::V1::Orchestrator
      @workflows = workflows #: Hash[String, Workflow]
      @coordinator = Coordinator.new(settings:, backend:, listener:, clock:, random:) #: Coordinator
      @inventory = inventory #: Orchestrator::inventory
      @jobs = jobs #: Integer
      @listener = listener #: Runner::listener
      @clock = clock #: ^() -> Time
      @nodes = {} #: Hash[String, Proto::V1::Node]
      @inventory_loaded_at = nil #: Time?
      # A pipe, as a thread blocked in Queue#pop misses a push from a signal handler on that thread.
      wakeup_reader, wakeup_writer = IO.pipe
      @wakeup_reader = wakeup_reader #: IO
      @wakeup_writer = wakeup_writer #: IO
      @stopping = false #: bool
    end

    # Runs batches of due nodes until {#stop} is called. Loading the inventory
    # the first time must succeed; later reload failures are reported and the
    # previous inventory is kept.
    #
    # @return [void]
    # @raise [Glazed::Error] when the first inventory load or the state backend fails
    #: () -> void
    def run
      notify(level: 'info', message: 'orchestrator started', owner: @coordinator.owner)
      until @stopping
        wait = tick
        wait_for_wakeup(wait)
      end
      notify(level: 'info', message: 'orchestrator stopped')
    end

    # Makes {#run} return after the current batch. Safe to call from a signal handler.
    #
    # @return [void]
    #: () -> void
    def stop = wake(STOP)

    # Makes {#run} reload the inventory before the next batch. Safe to call from a signal handler.
    #
    # @return [void]
    #: () -> void
    def reload_inventory = wake(RELOAD_INVENTORY)

    # Reloads the inventory when it is time, then runs one batch of due nodes
    # for each workflow in turn.
    #
    # @return [Float] seconds until the next check
    # @raise [Glazed::Error] when the first inventory load or the state backend fails
    #: () -> Float
    def tick
      now = @clock.call
      loaded_at = @inventory_loaded_at
      refresh_inventory(now) if loaded_at.nil? || now - loaded_at >= inventory_refresh_seconds
      @workflows.each_key { |workflow| run_batch(workflow, @coordinator.claim(workflow)) }
      next_wait
    end

    # @return [Integer] seconds between inventory reloads
    #: () -> Integer
    private def inventory_refresh_seconds = @settings.inventory_refresh_seconds.zero? ? DEFAULT_INVENTORY_REFRESH : @settings.inventory_refresh_seconds

    # @return [Integer] seconds between checks for due nodes
    #: () -> Integer
    private def poll_seconds = @settings.poll_seconds.zero? ? DEFAULT_POLL : @settings.poll_seconds

    # @param request [String] one byte naming the request
    # @return [void]
    #: (String request) -> void
    private def wake(request)
      @wakeup_writer.write_nonblock(request, exception: false)
      nil
    end

    # Waits for a request from {#stop} or {#reload_inventory}, or until the timeout.
    #
    # @param timeout [Float] seconds to wait at most
    # @return [void]
    #: (Float timeout) -> void
    private def wait_for_wakeup(timeout)
      return unless @wakeup_reader.wait_readable(timeout)

      requests = @wakeup_reader.readpartial(4096)
      @stopping = true if requests.include?(STOP)
      @inventory_loaded_at = nil if requests.include?(RELOAD_INVENTORY)
    end

    # Loads the inventory, and for each workflow adds records for new nodes and deletes those of nodes gone.
    #
    # @param now [Time] current time
    # @return [void]
    # @raise [StandardError] when loading the inventory fails the first time
    #: (Time now) -> void
    private def refresh_inventory(now)
      begin
        nodes = @inventory.call
      rescue StandardError => e
        raise if @inventory_loaded_at.nil?

        # A transient failure of an inventory source must not stop scheduled runs.
        notify(level: 'error', error: e.class.name, message: "inventory reload failed, keeping the previous one: #{e.message}")
        @inventory_loaded_at = now
        return
      end

      @nodes = nodes.to_h { [it.name, it] }
      @inventory_loaded_at = now
      notify(level: 'info', message: 'inventory loaded', nodes: @nodes.size)
      @coordinator.sync_inventory(@nodes.keys)
    end

    # Runs the workflow for leased nodes and records the outcomes. When
    # interrupted, the leases are released so the nodes run again soon.
    #
    # @param workflow [String] workflow name
    # @param claimed [Array(String, Array<String>)] identifier of the batch, and names of the leased nodes
    # @return [void]
    # @raise [Interrupt] when the run is interrupted
    #: (String workflow, [String, Array[String]] claimed) -> void
    private def run_batch(workflow, claimed)
      owner, names = claimed
      return if names.empty?

      nodes = names.filter_map { @nodes[it] }
      notify(level: 'info', workflow:, message: 'batch started', nodes: nodes.map(&:name))
      begin
        errors = run_workflow(workflow, nodes)
      rescue Interrupt
        @coordinator.release(workflow, owner:, names:)
        raise
      end
      # Records of nodes gone from the inventory are deleted by the next reload.
      @coordinator.complete(workflow, owner:, names: names & @nodes.keys, errors:)
      notify(level: 'info', workflow:, message: 'batch finished', nodes: nodes.size, failed: errors.size)
    end

    # Runs a workflow. A batch step failure fails every node of the batch.
    #
    # @param workflow [String] workflow name
    # @param nodes [Array<Proto::V1::Node>] the nodes
    # @return [Hash{String => String}] errors of the failed nodes, by node name
    #: (String workflow, Array[Proto::V1::Node] nodes) -> Hash[String, String]
    private def run_workflow(workflow, nodes)
      result = Runner.new(workflow: @workflows.fetch(workflow), jobs: @jobs, listener: @listener).call(nodes)
      result.failures.to_h { [it.node.name, "#{it.step}: #{it.error.message}"] }
    rescue StandardError => e
      # The nodes are scheduled for retry instead of the orchestrator stopping.
      notify(level: 'error', workflow:, error: e.class.name, message: "batch failed: #{e.message}", backtrace: e.backtrace || [])
      nodes.to_h { [it.name, "#{e.class}: #{e.message}"] }
    end

    # @return [Float] seconds until the earliest known due date of any workflow, at most the poll interval
    #: () -> Float
    private def next_wait
      upcoming = @coordinator.next_due
      return poll_seconds.to_f unless upcoming

      (upcoming - @clock.call).clamp(0.0, poll_seconds.to_f).to_f
    end

    # @param event [Hash{Symbol => String, Integer, Boolean, Array<String>, nil}] event fields
    # @return [void]
    #: (**Runner::event_value event) -> void
    private def notify(**event) = @listener.call(event)
  end
end
