# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'digest'
require 'json'
require 'aws-sdk-s3'
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
    # `glazed/aws/lambda.Glazed::Aws::Lambda.handler`. The config is read from
    # the S3 object GLAZED_CONFIG_S3_BUCKET and GLAZED_CONFIG_S3_KEY name,
    # which must have the SHA-256 in GLAZED_CONFIG_S3_DIGEST, or else from the
    # file GLAZED_CONFIG_FILE names. Events are `{"task":
    # <glazed.v1.CoordinatorTask>, "execution_input": <execution input>}`;
    # signals in the execution input are added to a check task. The result is
    # the task's result as ProtoJSON.
    module Lambda
      # Environment variable naming the config file.
      CONFIG_FILE_ENV = 'GLAZED_CONFIG_FILE' #: String
      # Environment variable naming the bucket of the config object.
      CONFIG_S3_BUCKET_ENV = 'GLAZED_CONFIG_S3_BUCKET' #: String
      # Environment variable naming the key of the config object.
      CONFIG_S3_KEY_ENV = 'GLAZED_CONFIG_S3_KEY' #: String
      # Environment variable holding the SHA-256 of the config object, in base64.
      CONFIG_S3_DIGEST_ENV = 'GLAZED_CONFIG_S3_DIGEST' #: String
      # Environment variable naming the region of the config bucket; the SDK default when unset.
      CONFIG_S3_REGION_ENV = 'GLAZED_CONFIG_S3_REGION' #: String

      # What a warm function keeps between invocations.
      class Function
        # Builds the task runner of a config.
        #
        # @param config [Proto::V1::Config] the config
        # @param source [String] where the config comes from
        # @param listener [Proc] receives events
        # @return [Function] the function
        # @raise [Glazed::Error] when the config lacks orchestrator settings
        #: (Proto::V1::Config config, source: String, listener: Runner::listener) -> Function
        def self.build(config, source:, listener:)
          settings = config.orchestrator or raise Glazed::Error, "#{source}: orchestrator is not configured"
          context = StepContext.from_proto(config.storages, listener:)
          workflows = settings.workflows.keys.to_h do |name|
            definition = config.workflows[name] or raise Glazed::Error, "#{source}: no workflow named #{name.inspect}"
            [name, Workflow.from_proto(definition, context:)]
          end
          backend = StateBackends.build(Must.because(settings.state) { 'validation requires orchestrator.state' }, context:)
          coordinator = Coordinator.new(settings:, backend:, listener:)
          runner = Coordinator::TaskRunner.new(coordinator:, workflows:, inventory: -> { Sources.nodes(config.inventory.to_a) }, listener:)
          new(source:, runner:)
        end

        # @param source [String] where the config comes from
        # @param runner [Coordinator::TaskRunner] performs the tasks
        #: (source: String, runner: Coordinator::TaskRunner) -> void
        def initialize(source:, runner:)
          @source = source #: String
          @runner = runner #: Coordinator::TaskRunner
        end

        # @return [String] where the config comes from
        #: String
        attr_reader :source
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

      # Performs the task of an event. The config is loaded once per source,
      # so a changed object in S3 is read only when its digest changes.
      #
      # @param event [Hash] the event
      # @param environment [Hash{String => String}] environment variables
      # @param listener [Proc] receives events; JSON lines on standard error by default
      # @param s3 [Aws::S3::Client, nil] client reading the config object; built from the environment when nil
      # @return [Hash] the task's result as ProtoJSON
      # @raise [Glazed::Error] when the config is missing, invalid or not of the expected digest, or the task fails
      #: (Hash[String, untyped] event, environment: Hash[String, String], ?listener: Runner::listener, ?s3: ::Aws::S3::Client?) -> Hash[String, untyped]
      def self.handle(event, environment:, listener: ->(event) { $stderr.puts(JSON.generate(event)) }, s3: nil)
        source = config_source(environment)
        function = @function
        if function.nil? || function.source != source
          function = @function = Function.build(load_config(environment, s3:), source:, listener:)
        end

        task = ProtoJson.load(Proto::V1::CoordinatorTask, JSON.generate(event.fetch('task')))
        if (check = task.check) && event.key?('execution_input')
          SignalEvents.extract(event['execution_input'], listener:).each { check.signals << it }
        end
        JSON.parse(ProtoJson.dump(function.runner.perform(task)))
      end

      # @param environment [Hash{String => String}] environment variables
      # @return [String] where the config comes from: the S3 object and its digest, or the file
      # @raise [Glazed::Error] when neither is set, or the S3 object is set partly
      #: (Hash[String, String] environment) -> String
      private_class_method def self.config_source(environment)
        bucket = environment[CONFIG_S3_BUCKET_ENV]
        return environment.fetch(CONFIG_FILE_ENV) { raise Glazed::Error, "#{CONFIG_S3_BUCKET_ENV} or #{CONFIG_FILE_ENV} is required" } unless bucket

        key = environment.fetch(CONFIG_S3_KEY_ENV) { raise Glazed::Error, "#{CONFIG_S3_KEY_ENV} is required with #{CONFIG_S3_BUCKET_ENV}" }
        digest = environment.fetch(CONFIG_S3_DIGEST_ENV) { raise Glazed::Error, "#{CONFIG_S3_DIGEST_ENV} is required with #{CONFIG_S3_BUCKET_ENV}" }
        "s3://#{bucket}/#{key}##{digest}"
      end

      # @param environment [Hash{String => String}] environment variables
      # @param s3 [Aws::S3::Client, nil] client reading the config object; built from the environment when nil
      # @return [Proto::V1::Config] the config
      # @raise [Glazed::Error] when the config is invalid, or the S3 object is not of the expected digest
      #: (Hash[String, String] environment, s3: ::Aws::S3::Client?) -> Proto::V1::Config
      private_class_method def self.load_config(environment, s3:)
        bucket = environment[CONFIG_S3_BUCKET_ENV]
        return Glazed::Config.load(environment.fetch(CONFIG_FILE_ENV)) unless bucket

        key = environment.fetch(CONFIG_S3_KEY_ENV)
        origin = "s3://#{bucket}/#{key}"
        region = environment[CONFIG_S3_REGION_ENV]
        s3 ||= region ? ::Aws::S3::Client.new(region:) : ::Aws::S3::Client.new
        json = s3.get_object(bucket:, key:).body.read.force_encoding(Encoding::UTF_8)
        # The digest pins the object the function was deployed with.
        actual = [Digest::SHA256.digest(json)].pack('m0')
        expected = environment.fetch(CONFIG_S3_DIGEST_ENV)
        raise Glazed::Error, "#{origin} has SHA-256 #{actual}, not #{expected} in #{CONFIG_S3_DIGEST_ENV}" unless actual == expected

        Glazed::Config.parse(json, origin:)
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
