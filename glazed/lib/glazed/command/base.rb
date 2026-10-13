# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'dry/cli'
require 'glazed'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/proto_json'
require 'glazed/runner'
require 'glazed/state_backends'
require 'glazed/step_context'
require 'glazed/validation'

module Glazed
  module Command
    # Base of glazed's commands, giving them the output streams dry-cli
    # injects (or the process's own when run directly).
    class Base < Dry::CLI::Command
      # Nodes processed in parallel when the config sets none.
      DEFAULT_JOBS = 4 #: Integer
      # Environment variable naming the config file when --config is omitted.
      CONFIG_FILE_ENV = 'GLAZED_CONFIG_FILE' #: String

      # @return [IO] standard output
      #: () -> IO
      private def out = instance_variable_get(:@out) || $stdout

      # @return [IO] standard error
      #: () -> IO
      private def err = instance_variable_get(:@err) || $stderr

      # Exits 1 with a message when neither --config nor {CONFIG_FILE_ENV} names the config file.
      #
      # @param config [String, nil] the --config option
      # @param command [String] command name, for the message
      # @return [String] path of the config file
      #: (String? config, String command) -> String
      private def config_path(config, command)
        path = config || ENV.fetch(CONFIG_FILE_ENV, '')
        return path unless path.empty?

        err.puts "glazed #{command}: --config or #{CONFIG_FILE_ENV} is required"
        exit 1
      end

      # @return [Proc] listener writing each event to standard error as a JSON line
      #: () -> Runner::listener
      private def json_listener
        lock = Mutex.new
        ->(event) { lock.synchronize { err.puts(JSON.generate(event)) } }
      end

      # @param config [Proto::V1::Config] the config
      # @param path [String] config file, for the error message
      # @return [Proto::V1::Orchestrator] the orchestrator settings
      # @raise [Glazed::Error] when the config has none
      #: (Proto::V1::Config config, String path) -> Proto::V1::Orchestrator
      private def orchestrator_settings(config, path)
        config.orchestrator or raise Glazed::Error, "#{path}: orchestrator is not configured"
      end

      # @param orchestration [Proto::V1::Orchestrator] the orchestrator settings
      # @param names [Array<String>, nil] requested workflows; every orchestrated one when nil
      # @return [Array<String>] the workflows, without duplicates
      # @raise [Glazed::Error] when a requested workflow is not orchestrated
      #: (Proto::V1::Orchestrator orchestration, Array[String]? names) -> Array[String]
      private def select_orchestrated(orchestration, names)
        orchestrated = orchestration.workflows.keys.sort
        return orchestrated unless names

        unknown = names - orchestrated
        raise Glazed::Error, "not orchestrated workflows: #{unknown.join(', ')}" unless unknown.empty?

        names.uniq
      end

      # @param orchestration [Proto::V1::Orchestrator] the orchestrator settings
      # @param context [StepContext] configured storages
      # @return [StateBackends::Base] the state backend
      # @raise [Glazed::Error] when the backend cannot be built
      #: (Proto::V1::Orchestrator orchestration, StepContext context) -> StateBackends::Base
      private def state_backend(orchestration, context)
        StateBackends.build(Must.because(orchestration.state) { 'validation requires orchestrator.state' }, context:)
      end

      # @param config [Proto::V1::Config] the config
      # @return [Integer] nodes processed in parallel
      #: (Proto::V1::Config config) -> Integer
      private def default_jobs(config) = config.jobs.zero? ? DEFAULT_JOBS : config.jobs

      # Reads the config, first requiring the features its `requires` lists so
      # plugin settings types are known when it is decoded.
      #
      # @param path [String] config file
      # @return [Proto::V1::Config] the config
      # @raise [Glazed::Error] when `requires` is malformed, or the config does not decode
      # @raise [InvalidMessage] when the config breaks the rules of its schema
      # @raise [LoadError] when a required feature is missing
      #: (String path) -> Proto::V1::Config
      private def load_config(path)
        json = ::File.read(path)
        document = JSON.parse(json) #: untyped
        requires = document.is_a?(Hash) ? document.fetch('requires', []) : []
        unless requires.is_a?(Array) && requires.all?(String)
          raise Glazed::Error, "#{path}: requires must be a list of strings"
        end

        requires.each { require it }
        ProtoJson.load(Proto::V1::Config, json).tap { Validation.validate!(it, origin: path) }
      rescue Google::Protobuf::ParseError, JSON::ParserError => e
        hint = e.message.include?('Type was not found') ? '; list the gem providing that plugin type in requires' : ''
        raise Glazed::Error, "#{path}: #{e.message}#{hint}"
      end

      # @param config [Proto::V1::Config] the config
      # @param name [String, nil] requested workflow
      # @return [Proto::V1::Workflow] the selected workflow
      # @raise [Glazed::Error] when the name is unknown, or none is given and the config has not exactly one
      #: (Proto::V1::Config config, String? name) -> Proto::V1::Workflow
      private def select_workflow(config, name)
        names = config.workflows.keys.sort
        name ||= names.first if names.size == 1
        raise Glazed::Error, "choose a workflow with --workflow: #{names.join(', ')}" unless name

        config.workflows[name] or raise Glazed::Error, "no workflow named #{name.inspect}"
      end

      # @param nodes [Array<Proto::V1::Node>] every node in the inventory
      # @param only [Array<String>] node names to keep; all when empty
      # @return [Array<Proto::V1::Node>] the selected nodes
      # @raise [Glazed::Error] when only names an unknown node
      #: (Array[Proto::V1::Node] nodes, Array[String] only) -> Array[Proto::V1::Node]
      private def select_nodes(nodes, only)
        return nodes if only.empty?

        unknown = only - nodes.map(&:name)
        raise Glazed::Error, "unknown nodes: #{unknown.join(', ')}" unless unknown.empty?

        nodes.select { only.include?(it.name) }
      end
    end
  end
end
