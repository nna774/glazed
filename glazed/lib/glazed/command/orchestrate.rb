# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/command/base'
require 'glazed/must'
require 'glazed/orchestrator'
require 'glazed/proto'
require 'glazed/sources'
require 'glazed/state_backends'
require 'glazed/step_context'
require 'glazed/workflow'

module Glazed
  module Command
    # `glazed orchestrate`: runs the orchestrator in the foreground until
    # terminated, logging JSON lines to standard error. TERM or INT stops it
    # after the current batch, and a second one interrupts the batch. HUP
    # reloads the inventory.
    class Orchestrate < Base
      desc 'Run the orchestrated workflows for each node as it becomes due, until terminated'
      option :config, aliases: ['-c'], desc: 'Config file, ProtoJSON of glazed.v1.Config; $GLAZED_CONFIG_FILE when omitted'
      option :jobs, aliases: ['-j'], type: :integer, desc: 'Nodes processed in parallel'

      # Runs the orchestrator until a signal stops it.
      #
      # @param config [String, nil] path of the config file; {Base::CONFIG_FILE_ENV} when nil
      # @param jobs [String, nil] parallelism overriding the config
      # @param _options [Hash] other options dry-cli passes, unused
      # @return [void]
      # @raise [Glazed::Error, Google::Protobuf::ParseError] when the config or inventory is invalid, or the state backend fails
      # @raise [Interrupt] when a second TERM or INT interrupts a batch
      #: (?config: String?, ?jobs: String?, **untyped _options) -> void
      def call(config: nil, jobs: nil, **_options)
        config = config_path(config, 'orchestrate')

        settings = load_config(config)
        orchestration = orchestrator_settings(settings, config)
        listener = json_listener
        context = StepContext.from_proto(settings.storages, redaction: settings.redaction, listener:)
        workflows = orchestration.workflows.keys.to_h { [it, Workflow.from_proto(select_workflow(settings, it), context:)] }
        backend = state_backend(orchestration, context)
        orchestrator = Orchestrator.new(
          settings: orchestration, workflows:, backend:, inventory: -> { Sources.nodes(settings.inventory.to_a) },
          jobs: resolve_jobs(jobs, settings), listener:,
        )
        with_traps(orchestrator) { orchestrator.run }
      ensure
        backend&.close
      end

      # Installs the signal handlers while the block runs.
      #
      # @param orchestrator [Orchestrator] the orchestrator to control
      # @yieldreturn [void]
      # @return [void]
      #: (Orchestrator orchestrator) { () -> void } -> void
      private def with_traps(orchestrator, &)
        stopping = false #: bool
        stop = proc do |_signo|
          raise Interrupt if stopping

          stopping = true
          orchestrator.stop
        end
        previous = {
          'TERM' => trap('TERM', &stop),
          'INT' => trap('INT', &stop),
          'HUP' => trap('HUP') { orchestrator.reload_inventory },
        } #: Hash[String, untyped]
        yield
      ensure
        previous&.each { |signal, handler| trap(signal, handler || 'DEFAULT') }
      end
    end
  end
end
