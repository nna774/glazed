# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'time'
require 'google/protobuf'
require 'glazed/command/base'
require 'glazed/must'
require 'glazed/orchestrator'
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
      argument :nodes, type: :array, required: true, desc: 'Names of the nodes'
      option :config, aliases: ['-c'], desc: 'Config file, ProtoJSON of glazed.v1.Config (required)'
      option :workflow, aliases: ['-w'], type: :array, desc: 'Signal only these orchestrated workflows, comma-separated'
      option :source, default: 'manual', desc: 'What sent the signal, recorded as the reason the node is due'
      option :now, type: :boolean, default: false, desc: 'Make the nodes due now, without the debounce delay'

      # Records the signals.
      #
      # @param nodes [Array<String>] node names
      # @param config [String, nil] path of the config file
      # @param workflow [Array<String>, nil] workflows to signal; every orchestrated one when nil
      # @param source [String] what sent the signal
      # @param now [Boolean] whether to skip the debounce delay
      # @param _options [Hash] other options dry-cli passes, unused
      # @return [void]
      # @raise [Glazed::Error, Google::Protobuf::ParseError] when the config is invalid, a node is unknown, or the state backend fails
      #: (nodes: Array[String], ?config: String?, ?workflow: Array[String]?, ?source: String, ?now: bool, **untyped _options) -> void
      def call(nodes:, config: nil, workflow: nil, source: 'manual', now: false, **_options)
        unless config
          err.puts 'glazed signal: --config is required'
          exit 1
        end

        settings = load_config(config)
        orchestration = orchestrator_settings(settings, config)
        workflows = workflow || orchestration.workflows.keys.sort
        unknown = workflows - orchestration.workflows.keys
        raise Glazed::Error, "not orchestrated workflows: #{unknown.join(', ')}" unless unknown.empty?

        select_nodes(Sources.nodes(settings.inventory.to_a), nodes)
        context = StepContext.from_proto(settings.storages, listener: json_listener)
        backend = StateBackends.build(Must.because(orchestration.state) { 'validation requires orchestrator.state' }, context:)
        at = Time.now
        signals = nodes.map do |node|
          Proto::V1::Signal.new(node:, source:, received_at: Google::Protobuf::Timestamp.from_time(at), immediate: now).tap { Validation.validate!(it) }
        end
        workflows.uniq.each do |name|
          debounce = orchestration.workflows[name]&.debounce
          records = Orchestrator.signal(backend:, workflow: name, signals:, debounce:, now: at)
          nodes.uniq.each do |node|
            due_at = Must.because(records.fetch(node).due_at) { 'validation requires due_at' }
            out.puts "#{node} #{name} due at #{due_at.to_time.utc.iso8601}"
          end
        end
      ensure
        backend&.close
      end
    end
  end
end
