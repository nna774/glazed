# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'glazed/aws'
require 'glazed/aws/state_machine'
require 'glazed/command/base'

module Glazed
  module Aws
    module Command
      # `glazed-aws state-machine`: prints the Amazon States Language
      # definition running the orchestrated workflows of a config with the
      # glazed-aws Lambda function. Storages that need care under Step
      # Functions are warned about on standard error.
      class StateMachine < Glazed::Command::Base
        desc 'Print the Step Functions state machine definition for the orchestrated workflows'
        option :config, aliases: ['-c'], desc: 'Config file, ProtoJSON of glazed.v1.Config; $GLAZED_CONFIG_FILE when omitted'
        option :function_arn, desc: 'ARN of the Lambda function with the glazed/aws/lambda handler'
        option :max_concurrency, type: :integer, desc: 'Nodes processed in parallel; jobs in the config by default'
        option :grace_seconds, type: :integer, desc: 'Seconds after waking until another execution may take over; the longest lease by default'
        option :max_cycles, type: :integer, desc: 'Cycles after which an execution ends, leaving later ones to the next; 20 by default'

        # Prints the definition.
        #
        # @param function_arn [String, nil] ARN of the Lambda function; required
        # @param config [String, nil] path of the config file; {Glazed::Command::Base::CONFIG_FILE_ENV} when nil
        # @param max_concurrency [String, nil] nodes processed in parallel
        # @param grace_seconds [String, nil] seconds after waking until another execution may take over
        # @param max_cycles [String, nil] cycles after which an execution ends
        # @param _options [Hash] other options dry-cli passes, unused
        # @return [void]
        # @raise [Glazed::Error] when the config is invalid, or a workflow cannot run under Step Functions
        #: (?function_arn: String?, ?config: String?, ?max_concurrency: String?, ?grace_seconds: String?, ?max_cycles: String?, **untyped _options) -> void
        def call(function_arn: nil, config: nil, max_concurrency: nil, grace_seconds: nil, max_cycles: nil, **_options)
          path = config_path(config, 'state-machine')
          unless function_arn
            err.puts 'glazed-aws state-machine: --function-arn is required'
            exit 1
          end

          settings = load_config(path)
          orchestrator_settings(settings, path)
          # dry-cli passes integer options as strings.
          definition = Aws::StateMachine.new(
            config: settings, function_arn:,
            max_concurrency: max_concurrency&.then { Integer(it) }, grace_seconds: grace_seconds&.then { Integer(it) }, max_cycles: max_cycles&.then { Integer(it) },
          )
          out.puts JSON.pretty_generate(definition.to_h)
          definition.warnings.each { err.puts "glazed-aws state-machine: #{it}" }
        end
      end
    end
  end
end
