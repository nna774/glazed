# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/command/base'
require 'glazed/proto'
require 'glazed/runner'
require 'glazed/sources'
require 'glazed/step_context'
require 'glazed/workflow'

module Glazed
  module Command
    # `glazed run`: runs one workflow of the config against the inventory in
    # this process. Nodes that fail a step are logged and skipped, and make the
    # exit status 1.
    class Run < Base
      desc 'Run a workflow of the config against the inventory'
      option :config, aliases: ['-c'], desc: 'Config file, ProtoJSON of glazed.v1.Config; $GLAZED_CONFIG_FILE when omitted'
      option :workflow, aliases: ['-w'], desc: 'Workflow to run; optional when the config defines one'
      option :only, type: :array, desc: 'Run only for these nodes, comma-separated'
      option :jobs, aliases: ['-j'], type: :integer, desc: 'Nodes processed in parallel'

      # Runs the workflow, exiting 1 when a node failed or --config is missing.
      #
      # @param config [String, nil] path of the config file; {Base::CONFIG_FILE_ENV} when nil
      # @param workflow [String, nil] workflow name; the only one when nil
      # @param only [Array<String>, nil] node names to run for; all when nil
      # @param jobs [Integer, nil] parallelism overriding the config
      # @param _options [Hash] other options dry-cli passes, unused
      # @return [void]
      # @raise [Glazed::Error, Google::Protobuf::ParseError] when the config, inventory or a batch step fails
      #: (?config: String?, ?workflow: String?, ?only: Array[String]?, ?jobs: Integer?, **untyped _options) -> void
      def call(config: nil, workflow: nil, only: nil, jobs: nil, **_options)
        config = config_path(config, 'run')

        settings = load_config(config)
        listener = json_listener
        context = StepContext.from_proto(settings.storages, listener:)
        steps = Workflow.from_proto(select_workflow(settings, workflow), context:)
        nodes = select_nodes(Sources.nodes(settings.inventory.to_a), only || [])

        jobs ||= default_jobs(settings)
        result = Runner.new(workflow: steps, jobs:, listener:).call(nodes)
        out.puts "completed #{result.states.size} of #{nodes.size} nodes, #{result.changed.size} changed, #{result.failures.size} failed"
        exit 1 unless result.failures.empty?
      end
    end
  end
end
