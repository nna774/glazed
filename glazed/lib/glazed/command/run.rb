# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'optparse'
require 'glazed/command'
require 'glazed/proto'
require 'glazed/proto_json'
require 'glazed/runner'
require 'glazed/sources'
require 'glazed/steps'
require 'glazed/workflow'

module Glazed
  module Command
    # `glazed run`: runs one workflow of the config against the inventory in
    # this process. Nodes that fail a step are logged and skipped, and make the
    # exit status 1.
    class Run
      # Nodes processed in parallel when the config sets none.
      DEFAULT_JOBS = 4 #: Integer

      # Parses the run subcommand's options.
      #
      # @param args [Array<String>] arguments after "run"
      # @return [Run] the command
      # @raise [OptionParser::ParseError] for invalid options or a missing config
      #: (Array[String] args) -> Run
      def self.parse(args)
        config_path = nil #: String?
        workflow = nil #: String?
        only = [] #: Array[String]
        jobs = nil #: Integer?
        parser = OptionParser.new do |opts|
          opts.banner = 'Usage: glazed run -c CONFIG [-w WORKFLOW] [--only NAME]... [--jobs N]'
          opts.on('-c', '--config PATH', 'Config file (ProtoJSON of glazed.v1.Config)') { config_path = it }
          opts.on('-w', '--workflow NAME', 'Workflow to run; optional when the config has one') { workflow = it }
          opts.on('--only NAME', 'Run only for this node; repeatable') { only << it }
          opts.on('-j', '--jobs N', Integer, 'Nodes processed in parallel') { jobs = it }
        end
        parser.parse!(args.dup)
        raise OptionParser::MissingArgument, '--config' unless config_path

        new(config_path:, workflow:, only:, jobs:)
      end

      # @param config_path [String] path of the config file
      # @param workflow [String, nil] workflow name; the only one when nil
      # @param only [Array<String>] node names to run for; all when empty
      # @param jobs [Integer, nil] parallelism overriding the config
      #: (config_path: String, ?workflow: String?, ?only: Array[String], ?jobs: Integer?) -> void
      def initialize(config_path:, workflow: nil, only: [], jobs: nil)
        @config_path = config_path #: String
        @workflow = workflow #: String?
        @only = only #: Array[String]
        @jobs = jobs #: Integer?
      end

      # Runs the workflow.
      #
      # @param out [IO] standard output, which receives a summary line
      # @param err [IO] standard error, which receives JSON log lines
      # @return [Integer] 0 when every node completed, 1 otherwise
      # @raise [Glazed::Error, Google::Protobuf::ParseError] when the config, inventory or a batch step fails
      #: (out: IO, err: IO) -> Integer
      def call(out:, err:)
        config = ProtoJson.load(Proto::V1::Config, File.read(@config_path))
        context = Steps::Context.from_proto(config.storages)
        workflow = Workflow.from_proto(select_workflow(config), context:)
        nodes = select_nodes(Sources.nodes(config.inventory.to_a))

        jobs = @jobs || (config.jobs.zero? ? DEFAULT_JOBS : config.jobs)
        result = Runner.new(workflow:, jobs:, listener: ->(event) { err.puts(JSON.generate(event)) }).call(nodes)
        out.puts "completed #{result.states.size} of #{nodes.size} nodes, #{result.failures.size} failed"
        result.failures.empty? ? 0 : 1
      end

      # @param config [Proto::V1::Config] the config
      # @return [Proto::V1::Workflow] the selected workflow
      # @raise [Glazed::Error] when the name is unknown, or none is given and the config has not exactly one
      #: (Proto::V1::Config config) -> Proto::V1::Workflow
      private def select_workflow(config)
        names = config.workflows.keys.sort
        name = @workflow || (names.size == 1 ? names.first : nil)
        raise Glazed::Error, "choose a workflow with --workflow: #{names.join(', ')}" unless name

        config.workflows[name] or raise Glazed::Error, "no workflow named #{name.inspect}"
      end

      # @param nodes [Array<Proto::V1::Node>] every node in the inventory
      # @return [Array<Proto::V1::Node>] the nodes selected with --only
      # @raise [Glazed::Error] when --only names an unknown node
      #: (Array[Proto::V1::Node] nodes) -> Array[Proto::V1::Node]
      private def select_nodes(nodes)
        return nodes if @only.empty?

        unknown = @only - nodes.map(&:name)
        raise Glazed::Error, "unknown nodes: #{unknown.join(', ')}" unless unknown.empty?

        nodes.select { @only.include?(it.name) }
      end
    end
  end
end
