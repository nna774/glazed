# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'time'
require 'google/protobuf'
require 'glazed/command/base'
require 'glazed/coordinator'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/sources'
require 'glazed/state_backends'
require 'glazed/step_context'
require 'glazed/validation'

module Glazed
  module Command
    # `glazed signal`: asks the orchestrator to run nodes soon, such as after
    # their configuration changed. The signal is recorded in the state backend
    # for every orchestrated workflow, or those chosen, with each workflow's
    # debounce, so `glazed orchestrate` need not be reachable. It prints when
    # each node is due.
    class SendSignal < Base
      desc 'Make nodes due soon for glazed orchestrate'
      argument :nodes, type: :array, required: false, desc: 'Names of the nodes'
      option :config, aliases: ['-c'], desc: 'Config file, ProtoJSON of glazed.v1.Config; $GLAZED_CONFIG_FILE when omitted'
      option :workflow, aliases: ['-w'], type: :array, desc: 'Signal only these orchestrated workflows, comma-separated'
      option :all, type: :boolean, default: false, desc: 'Signal every node in the inventory instead of the named ones'
      option :source, default: 'manual', desc: 'What sent the signal, recorded as the reason the node is due'
      option :now, type: :boolean, default: false, desc: 'Make the nodes due now, without the debounce delay'

      # Records the signals.
      #
      # @param nodes [Array<String>, nil] node names; none with all
      # @param config [String, nil] path of the config file; {Base::CONFIG_FILE_ENV} when nil
      # @param workflow [Array<String>, nil] workflows to signal; every orchestrated one when nil
      # @param all [Boolean] whether to signal every node in the inventory
      # @param source [String] what sent the signal
      # @param now [Boolean] whether to skip the debounce delay
      # @param _options [Hash] other options dry-cli passes, unused
      # @return [void]
      # @raise [Glazed::Error, Google::Protobuf::ParseError] when the config is invalid, a node is unknown, or the state backend fails
      #: (?nodes: Array[String]?, ?config: String?, ?workflow: Array[String]?, ?all: bool, ?source: String, ?now: bool, **untyped _options) -> void
      def call(nodes: nil, config: nil, workflow: nil, all: false, source: 'manual', now: false, **_options)
        config = config_path(config, 'signal')
        nodes ||= []
        if all != nodes.empty?
          err.puts 'glazed signal: name nodes, or give --all'
          exit 1
        end

        settings = load_config(config)
        orchestration = orchestrator_settings(settings, config)
        workflows = select_orchestrated(orchestration, workflow)
        inventory = Sources.nodes(settings.inventory.to_a)
        select_nodes(inventory, nodes)
        context = StepContext.from_proto(settings.storages, listener: json_listener)
        backend = state_backend(orchestration, context)
        at = Time.now
        received_at = Google::Protobuf::Timestamp.from_time(at)
        signals = (all ? [nil] : nodes.uniq).map do |node|
          Proto::V1::Signal.new(node: node || '', all_nodes: all, source:, received_at:, immediate: now, workflows:).tap { Validation.validate!(it) }
        end
        records = Coordinator.new(settings: orchestration, backend:, clock: -> { at }).signal(signals, nodes: inventory)
        workflows.each do |name|
          records.fetch(name, {}).each_value do |record|
            due_at = Must.because(record.due_at) { 'validation requires due_at' }
            out.puts "#{record.node} #{name} due at #{due_at.to_time.utc.iso8601}"
          end
        end
      ensure
        backend&.close
      end
    end
  end
end
