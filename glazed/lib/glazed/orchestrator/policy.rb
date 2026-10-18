# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'glazed'
require 'glazed/proto'
require 'glazed/must'

module Glazed
  class Orchestrator
    # How node schedules change on inventory changes, signals, claims and
    # completed runs. Each function returns a new record and leaves the given
    # one untouched, so state backends may call them more than once.
    module Policy
      # Seconds between runs when the schedule sets none.
      DEFAULT_INTERVAL = 3600 #: Integer
      # Seconds a signal waits for further signals when the debounce sets none.
      DEFAULT_DELAY = 60 #: Integer
      # Seconds after the first signal by which a node runs when the debounce sets none.
      DEFAULT_MAX_WAIT = 600 #: Integer

      # @param orchestration [Proto::V1::Orchestration] how the workflow is orchestrated
      # @param node [Proto::V1::Node] the node
      # @return [Proto::V1::Schedule, nil] schedule of the first rule matching the node that sets one, else the workflow's
      #: (Proto::V1::Orchestration orchestration, Proto::V1::Node node) -> Proto::V1::Schedule?
      def self.schedule_for(orchestration, node)
        orchestration.schedule_rules.find { it.schedule && matches?(Must.because(it.match) { 'validation requires match' }, node) }&.schedule ||
          orchestration.schedule
      end

      # @param orchestration [Proto::V1::Orchestration] how the workflow is orchestrated
      # @param node [Proto::V1::Node] the node
      # @return [Proto::V1::Debounce, nil] debounce of the first rule matching the node that sets one, else the workflow's
      #: (Proto::V1::Orchestration orchestration, Proto::V1::Node node) -> Proto::V1::Debounce?
      def self.debounce_for(orchestration, node)
        orchestration.schedule_rules.find { it.debounce && matches?(Must.because(it.match) { 'validation requires match' }, node) }&.debounce ||
          orchestration.debounce
      end

      # @param match [Proto::V1::NodeMatch] the criteria
      # @param node [Proto::V1::Node] the node
      # @return [Boolean] whether the node meets every criterion set
      #: (Proto::V1::NodeMatch match, Proto::V1::Node node) -> bool
      def self.matches?(match, node)
        return false unless match.names.empty? || match.names.include?(node.name)
        return false unless match.groups.empty? || match.groups.include?(node.group)

        match.name_regexp.empty? || Regexp.new("\\A(?:#{match.name_regexp})\\z").match?(node.name)
      end

      # Record of a node new to the inventory, due within the schedule's jitter.
      #
      # @param workflow [String] workflow name
      # @param node [String] node name
      # @param now [Time] current time
      # @param schedule [Proto::V1::Schedule, nil] the schedule
      # @param random [Random] source of jitter
      # @return [Proto::V1::NodeSchedule] the record
      #: (String workflow, String node, now: Time, schedule: Proto::V1::Schedule?, random: Random) -> Proto::V1::NodeSchedule
      def self.discovered(workflow, node, now:, schedule:, random:)
        due = timestamp(now + jitter(schedule, random))
        Proto::V1::NodeSchedule.new(workflow:, node:, due_at: due, scheduled_at: due, due_reason: 'inventory')
      end

      # Applies a signal with trailing debounce: the node becomes due the
      # debounce delay after the latest signal, but no later than the maximum
      # wait after the first signal not yet followed by a run. An earlier
      # scheduled run is kept, unless the node is running, as that run started
      # before the signal.
      #
      # @param record [Proto::V1::NodeSchedule, nil] the node's record; nil when it has none yet
      # @param signal [Proto::V1::Signal] the signal
      # @param workflow [String] workflow name
      # @param now [Time] current time, used when the signal has no reception time
      # @param debounce [Proto::V1::Debounce, nil] the debounce settings
      # @return [Proto::V1::NodeSchedule] the record
      #: (Proto::V1::NodeSchedule? record, Proto::V1::Signal signal, workflow: String, now: Time, debounce: Proto::V1::Debounce?) -> Proto::V1::NodeSchedule
      def self.signal(record, signal, workflow:, now:, debounce:)
        at = time(signal.received_at) || now
        updated = record&.dup || Proto::V1::NodeSchedule.new(workflow:, node: signal.node)
        running = running?(updated, now)
        window = time(updated.signal_window_started_at)
        started = time(updated.last_started_at)
        window = at if window.nil? || (running && started && window <= started)

        due = if signal.immediate
          at
        else
          [at + nonzero(debounce&.delay_seconds, DEFAULT_DELAY), window + nonzero(debounce&.max_wait_seconds, DEFAULT_MAX_WAIT)].min
        end
        scheduled = time(updated.scheduled_at)
        if !running && scheduled && scheduled <= due
          updated.due_at = timestamp(scheduled)
        else
          updated.due_at = timestamp(due)
          updated.due_reason = signal.source
        end
        updated.signal_window_started_at = timestamp(window)
        updated
      end

      # Leases a due node to an orchestrator.
      #
      # @param record [Proto::V1::NodeSchedule, nil] the node's record
      # @param owner [String] identifier of the claiming orchestrator and batch
      # @param now [Time] current time
      # @param lease_seconds [Integer] seconds the lease lasts
      # @return [Proto::V1::NodeSchedule, nil] the leased record; the record unchanged when it is not due or leased to another
      #: (Proto::V1::NodeSchedule? record, owner: String, now: Time, lease_seconds: Integer) -> Proto::V1::NodeSchedule?
      def self.claim(record, owner:, now:, lease_seconds:)
        return record unless record
        return record if running?(record, now)

        due = time(record.due_at)
        return record unless due && due <= now

        record.dup.tap do |claimed|
          claimed.lease_owner = owner
          claimed.lease_until = timestamp(now + lease_seconds)
          claimed.last_started_at = timestamp(now)
        end
      end

      # Records the outcome of a run and schedules the next one. A signal that
      # arrived during the run keeps its due date when that is earlier.
      #
      # @param record [Proto::V1::NodeSchedule, nil] the node's record
      # @param owner [String] identifier the run claimed the node with
      # @param finished_at [Time] when the run finished
      # @param error [String, nil] why the run failed; nil when it succeeded
      # @param schedule [Proto::V1::Schedule, nil] the schedule
      # @param random [Random] source of jitter
      # @return [Proto::V1::NodeSchedule, nil] the record; unchanged when another orchestrator holds it
      #: (Proto::V1::NodeSchedule? record, owner: String, finished_at: Time, error: String?, schedule: Proto::V1::Schedule?, random: Random) -> Proto::V1::NodeSchedule?
      def self.completed(record, owner:, finished_at:, error:, schedule:, random:)
        return record unless record && record.lease_owner == owner

        interval = nonzero(schedule&.interval_seconds, DEFAULT_INTERVAL)
        interval = nonzero(schedule&.retry_interval_seconds, interval) if error
        due = finished_at + interval + jitter(schedule, random)
        window = time(record.signal_window_started_at)
        started = time(record.last_started_at)
        pending = window && started && window > started

        record.dup.tap do |updated|
          updated.lease_owner = ''
          updated.lease_until = nil
          updated.last_finished_at = timestamp(finished_at)
          updated.last_failed = !error.nil?
          updated.last_error = error || ''
          updated.consecutive_failures = error ? record.consecutive_failures + 1 : 0
          updated.scheduled_at = timestamp(due)
          current = time(record.due_at)
          unless pending && current && current <= due
            updated.due_at = timestamp(due)
            updated.due_reason = error ? 'retry' : 'schedule'
          end
          updated.signal_window_started_at = nil unless pending
        end
      end

      # Gives up a lease without recording a run, such as when the orchestrator is interrupted.
      #
      # @param record [Proto::V1::NodeSchedule, nil] the node's record
      # @param owner [String] identifier the node was claimed with
      # @return [Proto::V1::NodeSchedule, nil] the record without the lease; unchanged when another orchestrator holds it
      #: (Proto::V1::NodeSchedule? record, owner: String) -> Proto::V1::NodeSchedule?
      def self.released(record, owner:)
        return record unless record && record.lease_owner == owner

        record.dup.tap do |updated|
          updated.lease_owner = ''
          updated.lease_until = nil
        end
      end

      # Decides whether a coordinator execution waits for the next due node.
      # It does unless another live execution already waits until then, or
      # it has looped max_cycles times; a waiter that stops waiting gives up
      # its record. A waiter that ended without giving it up, such as by
      # failing, is live until its record expires unless alive tells otherwise.
      #
      # @param record [Proto::V1::Wakeup, nil] the current waiter
      # @param token [String] identifies the deciding execution
      # @param next_due [Time, nil] when a node may next be claimed; nil when never
      # @param now [Time] current time
      # @param gap [Integer] seconds the execution waits at least after its first cycle
      # @param grace [Integer] seconds after waking until another execution may take over
      # @param cycle [Integer] times the execution has run due nodes already
      # @param max_cycles [Integer] cycles after which the execution ends
      # @param alive [Proc] tells whether the execution of a waiter's token still runs
      # @return [Array(Proto::V1::Wakeup, Time), Array(Proto::V1::Wakeup, nil), Array(nil, nil)] the waiter
      #   record to keep, and when to wake; nil when the execution ends
      #: (Proto::V1::Wakeup? record, token: String, next_due: Time?, now: Time, gap: Integer, grace: Integer, cycle: Integer, max_cycles: Integer, ?alive: ^(String) -> bool) -> [Proto::V1::Wakeup?, Time?]
      def self.arm(record, token:, next_due:, now:, gap:, grace:, cycle:, max_cycles:, alive: ->(_token) { true })
        own = record&.owner == token
        return [own ? nil : record, nil] if next_due.nil? || cycle >= max_cycles

        wake = [next_due, cycle.zero? ? now : now + gap].max
        expires_at = time(record&.expires_at)
        wake_at = time(record&.wake_at)
        if record && !own && expires_at && expires_at > now && wake_at && wake_at <= wake && alive.call(record.owner)
          return [record, nil]
        end

        [Proto::V1::Wakeup.new(owner: token, wake_at: timestamp(wake), expires_at: timestamp(wake + grace)), wake]
      end

      # @param record [Proto::V1::NodeSchedule] the node's record
      # @param now [Time] current time
      # @return [Boolean] whether an orchestrator holds an unexpired lease on the node
      #: (Proto::V1::NodeSchedule record, Time now) -> bool
      def self.running?(record, now)
        lease_until = time(record.lease_until)
        !record.lease_owner.empty? && !lease_until.nil? && lease_until > now
      end

      # @param timestamp [Google::Protobuf::Timestamp, nil] the timestamp
      # @return [Time, nil] the time, or nil when unset
      #: (Google::Protobuf::Timestamp? timestamp) -> Time?
      def self.time(timestamp) = timestamp&.to_time

      # @param time [Time] the time
      # @return [Google::Protobuf::Timestamp] the timestamp
      #: (Time time) -> Google::Protobuf::Timestamp
      def self.timestamp(time) = Google::Protobuf::Timestamp.from_time(time)

      # @param schedule [Proto::V1::Schedule, nil] the schedule
      # @param random [Random] source of jitter
      # @return [Integer] seconds of jitter
      #: (Proto::V1::Schedule? schedule, Random random) -> Integer
      private_class_method def self.jitter(schedule, random)
        max = schedule&.jitter_seconds || 0
        max.zero? ? 0 : random.rand(max + 1)
      end

      # @param value [Integer, nil] configured value
      # @param default [Integer] value used when unset or 0
      # @return [Integer] the value
      #: (Integer? value, Integer default) -> Integer
      private_class_method def self.nonzero(value, default) = value.nil? || value.zero? ? default : value
    end
  end
end
