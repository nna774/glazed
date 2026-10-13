# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'glazed/command/base'
require 'glazed/proto'
require 'glazed/proto_json'
require 'glazed/runner'
require 'glazed/sources'
require 'glazed/step_context'
require 'glazed/validation'
require 'glazed/workflow'

module Glazed
  module Command
    # `glazed run`: runs one workflow of the config against the inventory in
    # this process. Nodes that fail a step are logged and skipped, and make the
    # exit status 1.
    class Run < Base
      # Nodes processed in parallel when the config sets none.
      DEFAULT_JOBS = 4 #: Integer

      desc 'Run a workflow of the config against the inventory'
      option :config, aliases: ['-c'], desc: 'Config file, ProtoJSON of glazed.v1.Config (required)'
      option :workflow, aliases: ['-w'], desc: 'Workflow to run; optional when the config defines one'
      option :only, type: :array, desc: 'Run only for these nodes, comma-separated'
      option :jobs, aliases: ['-j'], type: :integer, desc: 'Nodes processed in parallel'

      # Runs the workflow, exiting 1 when a node failed or --config is missing.
      #
      # @param config [String, nil] path of the config file
      # @param workflow [String, nil] workflow name; the only one when nil
      # @param only [Array<String>, nil] node names to run for; all when nil
      # @param jobs [Integer, nil] parallelism overriding the config
      # @param _options [Hash] other options dry-cli passes, unused
      # @return [void]
      # @raise [Glazed::Error, Google::Protobuf::ParseError] when the config, inventory or a batch step fails
      #: (?config: String?, ?workflow: String?, ?only: Array[String]?, ?jobs: Integer?, **untyped _options) -> void
      def call(config: nil, workflow: nil, only: nil, jobs: nil, **_options)
        unless config
          err.puts 'glazed run: --config is required'
          exit 1
        end

        settings = load_config(config)
        context = StepContext.from_proto(settings.storages)
        steps = Workflow.from_proto(select_workflow(settings, workflow), context:)
        nodes = select_nodes(Sources.nodes(settings.inventory.to_a), only || [])

        jobs ||= settings.jobs.zero? ? DEFAULT_JOBS : settings.jobs
        result = Runner.new(workflow: steps, jobs:, listener: ->(event) { err.puts(JSON.generate(event)) }).call(nodes)
        out.puts "completed #{result.states.size} of #{nodes.size} nodes, #{result.changed.size} changed, #{result.failures.size} failed"
        exit 1 unless result.failures.empty?
      end

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
