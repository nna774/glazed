# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'glazed'
require 'glazed/aws'
require 'glazed/aws/signal_events'
require 'glazed/config'
require 'glazed/coordinator'
require 'glazed/coordinator/task_runner'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/proto_json'
require 'glazed/runner'
require 'glazed/sources'
require 'glazed/state_backends'
require 'glazed/step_context'
require 'glazed/workflow'

module Glazed
  module Aws
    # AWS Lambda function performing the tasks of the state machine
    # {StateMachine} generates. Set the handler to
    # `glazed/aws/lambda.Glazed::Aws::Lambda.handler`, and GLAZED_CONFIG_FILE
    # to the config. Events are `{"task": <glazed.v1.CoordinatorTask>,
    # "execution_input": <execution input>}`; signals in the execution input
    # are added to a check task. The result is the task's result as ProtoJSON.
    module Lambda
      # Environment variable naming the config file.
      CONFIG_FILE_ENV = 'GLAZED_CONFIG_FILE' #: String

      # What a warm function keeps between invocations.
      class Function
        # Builds the task runner of a config.
        #
        # @param path [String] config file
        # @param listener [Proc] receives events
        # @return [Function] the function
        # @raise [Glazed::Error] when the config is invalid or lacks orchestrator settings
        #: (String path, listener: Runner::listener) -> Function
        def self.load(path, listener:)
          config = Glazed::Config.load(path)
          settings = config.orchestrator or raise Glazed::Error, "#{path}: orchestrator is not configured"
          context = StepContext.from_proto(config.storages, listener:)
          workflows = settings.workflows.keys.to_h do |name|
            definition = config.workflows[name] or raise Glazed::Error, "#{path}: no workflow named #{name.inspect}"
            [name, Workflow.from_proto(definition, context:)]
          end
          backend = StateBackends.build(Must.because(settings.state) { 'validation requires orchestrator.state' }, context:)
          coordinator = Coordinator.new(settings:, backend:, listener:)
          runner = Coordinator::TaskRunner.new(coordinator:, workflows:, inventory: -> { Sources.nodes(config.inventory.to_a) }, listener:)
          new(path:, runner:)
        end

        # @param path [String] config file
        # @param runner [Coordinator::TaskRunner] performs the tasks
        #: (path: String, runner: Coordinator::TaskRunner) -> void
        def initialize(path:, runner:)
          @path = path #: String
          @runner = runner #: Coordinator::TaskRunner
        end

        # @return [String] config file
        #: String
        attr_reader :path
        # @return [Coordinator::TaskRunner] performs the tasks
        #: Coordinator::TaskRunner
        attr_reader :runner
      end

      @function = nil #: Function?

      # Entry point of the Lambda runtime.
      #
      # @param event [Hash] the event
      # @param context [Object] the Lambda context, unused
      # @return [Hash] the task's result as ProtoJSON
      #: (event: Hash[String, untyped], context: untyped) -> Hash[String, untyped]
      def self.handler(event:, context:)
        handle(event, environment: ENV.to_h)
      end

      # Performs the task of an event. The config is loaded once per config path.
      #
      # @param event [Hash] the event
      # @param environment [Hash{String => String}] environment variables
      # @param listener [Proc] receives events; JSON lines on standard error by default
      # @return [Hash] the task's result as ProtoJSON
      # @raise [Glazed::Error] when the config is missing or invalid, or the task fails
      #: (Hash[String, untyped] event, environment: Hash[String, String], ?listener: Runner::listener) -> Hash[String, untyped]
      def self.handle(event, environment:, listener: ->(event) { $stderr.puts(JSON.generate(event)) })
        path = environment.fetch(CONFIG_FILE_ENV) { raise Glazed::Error, "#{CONFIG_FILE_ENV} is not set" }
        function = @function
        function = @function = Function.load(path, listener:) if function.nil? || function.path != path

        task = ProtoJson.load(Proto::V1::CoordinatorTask, JSON.generate(event.fetch('task')))
        if (check = task.check) && event.key?('execution_input')
          SignalEvents.extract(event['execution_input'], listener:).each { check.signals << it }
        end
        JSON.parse(ProtoJson.dump(function.runner.perform(task)))
      end

      # Forgets the loaded config, so the next event loads it again.
      #
      # @return [void]
      #: () -> void
      def self.reset
        @function = nil
      end
    end
  end
end
