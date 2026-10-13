# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/command/base'
require 'glazed/orchestrator'
require 'glazed/proto'
require 'glazed/proto_json'
require 'glazed/state_backends/base'
require 'glazed/step_context'

module Glazed
  module Command
    # `glazed status`: prints the orchestration state of each workflow and
    # node, as a table or as ProtoJSON lines. The exit status is 1 when a
    # listed node's last run failed or it is overdue, so it can serve as a
    # monitoring check.
    class Status < Base
      #: type row = Array[String]

      # Headings of the table columns.
      HEADINGS = ['WORKFLOW', 'NODE', 'STATUS', 'DUE', 'REASON', 'LAST RUN', 'RESULT'].freeze #: Array[String]

      desc 'Print when each node runs next and how its last run went'
      option :config, aliases: ['-c'], desc: 'Config file, ProtoJSON of glazed.v1.Config; $GLAZED_CONFIG_FILE when omitted'
      option :workflow, aliases: ['-w'], type: :array, desc: 'Show only these orchestrated workflows, comma-separated'
      option :only, type: :array, desc: 'Show only these nodes, comma-separated'
      option :failing, type: :boolean, default: false, desc: 'Show only nodes whose last run failed'
      option :json, type: :boolean, default: false, desc: 'Print each record as a line of ProtoJSON of glazed.v1.NodeSchedule'

      # Prints the records, exiting 1 when one of them is failing or overdue.
      #
      # @param config [String, nil] path of the config file; {Base::CONFIG_FILE_ENV} when nil
      # @param workflow [Array<String>, nil] workflows to show; every orchestrated one when nil
      # @param only [Array<String>, nil] nodes to show; all when nil
      # @param failing [Boolean] whether to show only nodes whose last run failed
      # @param json [Boolean] whether to print ProtoJSON lines instead of a table
      # @param _options [Hash] other options dry-cli passes, unused
      # @return [void]
      # @raise [Glazed::Error, Google::Protobuf::ParseError] when the config is invalid or the state backend fails
      #: (?config: String?, ?workflow: Array[String]?, ?only: Array[String]?, ?failing: bool, ?json: bool, **untyped _options) -> void
      def call(config: nil, workflow: nil, only: nil, failing: false, json: false, **_options)
        config = config_path(config, 'status')
        settings = load_config(config)
        orchestration = orchestrator_settings(settings, config)
        workflows = select_orchestrated(orchestration, workflow)
        backend = state_backend(orchestration, StepContext.from_proto(settings.storages, listener: json_listener))
        records = workflows.flat_map { backend.list(it) }
        records.select! { only.include?(it.node) } if only
        records.select!(&:last_failed) if failing

        now = Time.now
        poll_seconds = orchestration.poll_seconds.zero? ? Orchestrator::DEFAULT_POLL : orchestration.poll_seconds
        if json
          records.each { out.puts ProtoJson.dump(it) }
        else
          print_table(records.map { row(it, now:, poll_seconds:) })
        end
        exit 1 if records.any? { it.last_failed || status(it, now:, poll_seconds:) == 'overdue' }
      ensure
        backend&.close
      end

      # @param rows [Array<Array<String>>] cells of each row, the last being free-form notes
      # @return [void]
      #: (Array[Status::row] rows) -> void
      private def print_table(rows)
        widths = HEADINGS.each_index.map { |index| [HEADINGS.fetch(index), *rows.map { it.fetch(index) }].map(&:length).max || 0 }
        [HEADINGS, *rows].each do |cells|
          columns = HEADINGS.each_index.map { |index| cells.fetch(index).ljust(widths.fetch(index)) }
          out.puts [*columns, *cells.drop(HEADINGS.size)].join('  ').rstrip
        end
      end

      # @param record [Proto::V1::NodeSchedule] the record
      # @param now [Time] current time
      # @param poll_seconds [Integer] seconds between the orchestrator's checks for due nodes
      # @return [Array<String>] the cells, then the notes
      #: (Proto::V1::NodeSchedule record, now: Time, poll_seconds: Integer) -> Status::row
      private def row(record, now:, poll_seconds:)
        status = status(record, now:, poll_seconds:)
        due = time(record.due_at)
        due_cell = due ? clock(due, now) : '-'
        due_cell = "#{due_cell} (#{relative(due, now)})" if due && status != 'running'
        [record.workflow, record.node, status, due_cell, record.due_reason, last_run(record, now:), result(record), notes(record, now:).join('; ')]
      end

      # @param record [Proto::V1::NodeSchedule] the record
      # @param now [Time] current time
      # @param poll_seconds [Integer] seconds between the orchestrator's checks for due nodes
      # @return [String] "running", "overdue" when due for more than a poll interval, "due", or "waiting"
      #: (Proto::V1::NodeSchedule record, now: Time, poll_seconds: Integer) -> String
      private def status(record, now:, poll_seconds:)
        return 'running' if Orchestrator::Policy.running?(record, now)

        due = time(record.due_at)
        return 'waiting' if due.nil? || due > now

        now - due > poll_seconds ? 'overdue' : 'due'
      end

      # @param record [Proto::V1::NodeSchedule] the record
      # @param now [Time] current time
      # @return [String] start of the latest run with its duration, or "-" when it never ran
      #: (Proto::V1::NodeSchedule record, now: Time) -> String
      private def last_run(record, now:)
        started = time(record.last_started_at)
        return '-' unless started

        finished = time(record.last_finished_at)
        duration = finished && finished >= started ? format('%.1fs', finished - started) : 'running'
        "#{clock(started, now)} (#{duration})"
      end

      # @param record [Proto::V1::NodeSchedule] the record
      # @return [String] "ok", "failed ×N", or "-" when it never finished a run
      #: (Proto::V1::NodeSchedule record) -> String
      private def result(record)
        return "failed ×#{record.consecutive_failures}" if record.last_failed
        return '-' unless record.last_finished_at

        'ok'
      end

      # @param record [Proto::V1::NodeSchedule] the record
      # @param now [Time] current time
      # @return [Array<String>] the last error, a pending signal and the lease, where present
      #: (Proto::V1::NodeSchedule record, now: Time) -> Array[String]
      private def notes(record, now:)
        notes = [] #: Array[String]
        notes << record.last_error if record.last_failed && !record.last_error.empty?
        window = time(record.signal_window_started_at)
        started = time(record.last_started_at)
        notes << "signal pending since #{clock(window, now)}" if window && (started.nil? || window > started)
        lease_until = time(record.lease_until)
        notes << "lease #{record.lease_owner} until #{clock(lease_until, now)}" if !record.lease_owner.empty? && lease_until
        notes
      end

      # @param timestamp [Google::Protobuf::Timestamp, nil] the timestamp
      # @return [Time, nil] the time, or nil when unset
      #: (Google::Protobuf::Timestamp? timestamp) -> Time?
      private def time(timestamp) = Orchestrator::Policy.time(timestamp)

      # @param time [Time] the time
      # @param now [Time] current time
      # @return [String] the UTC time of day, with the date when it is not today
      #: (Time time, Time now) -> String
      private def clock(time, now)
        utc = time.getutc
        utc.strftime('%F') == now.getutc.strftime('%F') ? utc.strftime('%TZ') : utc.strftime('%FT%TZ')
      end

      # @param time [Time] the time
      # @param now [Time] current time
      # @return [String] such as "in 8m52s" or "4m16s ago"
      #: (Time time, Time now) -> String
      private def relative(time, now)
        seconds = (time - now).round
        seconds.negative? ? "#{span(-seconds)} ago" : "in #{span(seconds)}"
      end

      # @param seconds [Integer] non-negative seconds
      # @return [String] the span in its two largest units, such as "2d3h", "4m16s" or "9s"
      #: (Integer seconds) -> String
      private def span(seconds)
        minutes, secs = seconds.divmod(60)
        hours, mins = minutes.divmod(60)
        days, hrs = hours.divmod(24)
        return "#{days}d#{hrs}h" if days.positive?
        return "#{hours}h#{mins}m" if hours.positive?
        return "#{minutes}m#{secs}s" if minutes.positive?

        "#{secs}s"
      end
    end
  end
end
