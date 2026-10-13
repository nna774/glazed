# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'optparse'
require 'glazed/command'
require 'glazed/proto'
require 'glazed/proto_json'
require 'glazed/sources/json_files'
require 'glazed/steps/fetch'
require 'glazed/steps/publish'
require 'glazed/storages'

module Glazed
  module Command
    # `glazed run`: fetches every node in parallel, then publishes the results
    # in one batch. Nodes that fail are logged and skipped, and make the exit
    # status 1.
    class Run
      # Parallel fetches when the config sets none.
      DEFAULT_JOBS = 4 #: Integer

      # Parses the run subcommand's options.
      #
      # @param args [Array<String>] arguments after "run"
      # @return [Run] the command
      # @raise [OptionParser::ParseError] for invalid options or a missing config
      #: (Array[String] args) -> Run
      def self.parse(args)
        config_path = nil #: String?
        only = [] #: Array[String]
        jobs = nil #: Integer?
        parser = OptionParser.new do |opts|
          opts.banner = 'Usage: glazed run -c CONFIG [--only NAME]... [--jobs N]'
          opts.on('-c', '--config PATH', 'Config file (ProtoJSON of glazed.v1.Config)') { config_path = it }
          opts.on('--only NAME', 'Collect only this node; repeatable') { only << it }
          opts.on('-j', '--jobs N', Integer, 'Nodes collected in parallel') { jobs = it }
        end
        parser.parse!(args.dup)
        raise OptionParser::MissingArgument, '--config' unless config_path

        new(config_path:, only:, jobs:)
      end

      # @param config_path [String] path of the config file
      # @param only [Array<String>] node names to collect; all when empty
      # @param jobs [Integer, nil] parallel fetches overriding the config
      #: (config_path: String, ?only: Array[String], ?jobs: Integer?) -> void
      def initialize(config_path:, only: [], jobs: nil)
        @config_path = config_path #: String
        @only = only #: Array[String]
        @jobs = jobs #: Integer?
        @lock = Mutex.new #: Thread::Mutex
      end

      # Fetches and publishes.
      #
      # @param out [IO] standard output, which receives a summary line
      # @param err [IO] standard error, which receives JSON log lines
      # @return [Integer] 0 when every node succeeded, 1 otherwise
      # @raise [Glazed::Error, Google::Protobuf::ParseError] when the config, inventory or publishing fails
      #: (out: IO, err: IO) -> Integer
      def call(out:, err:)
        config = ProtoJson.load(Proto::V1::Config, File.read(@config_path))
        raw_storage = Storages.build(config.raw || raise(Glazed::Error, 'config sets no raw storage'))
        redacted_storage = Storages.build(config.redacted || raise(Glazed::Error, 'config sets no redacted storage'))
        fetch = Steps::Fetch.new(storage: raw_storage, timeout: config.timeout_seconds.zero? ? CliSession::DEFAULT_TIMEOUT : config.timeout_seconds)

        nodes = select_nodes(Sources::JsonFiles.new(paths: config.inventory.to_a).nodes)
        results = fetch_all(fetch, nodes, jobs: @jobs || (config.jobs.zero? ? DEFAULT_JOBS : config.jobs), err:)

        publish = Steps::Publish.new(raw_storage:, redacted_storage:, redaction: config.redaction || Proto::V1::Redaction.new)
        publish.call(Proto::V1::PublishRequest.new(entries: results))
        failed = nodes.size - results.size
        out.puts "fetched #{results.size} of #{nodes.size} nodes, #{failed} failed"
        failed.zero? ? 0 : 1
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

      # @param fetch [Steps::Fetch] the fetch step
      # @param nodes [Array<Proto::V1::Node>] nodes to fetch
      # @param jobs [Integer] parallel fetches
      # @param err [IO] log destination
      # @return [Array<Proto::V1::FetchResult>] results of the nodes that succeeded, in inventory order
      #: (Steps::Fetch fetch, Array[Proto::V1::Node] nodes, jobs: Integer, err: IO) -> Array[Proto::V1::FetchResult]
      private def fetch_all(fetch, nodes, jobs:, err:)
        queue = Thread::Queue.new(nodes.each_with_index.to_a)
        queue.close
        results = {} #: Hash[Integer, Proto::V1::FetchResult]
        workers = Array.new([jobs, nodes.size].min) do
          Thread.new do
            while (item = queue.pop)
              node, index = item
              result = fetch_one(fetch, node, err:)
              @lock.synchronize { results[index] = result } if result
            end
          end
        end
        workers.each(&:join)
        results.sort.map { |_, result| result }
      end

      # @param fetch [Steps::Fetch] the fetch step
      # @param node [Proto::V1::Node] node to fetch
      # @param err [IO] log destination
      # @return [Proto::V1::FetchResult, nil] the result, or nil when the node failed
      #: (Steps::Fetch fetch, Proto::V1::Node node, err: IO) -> Proto::V1::FetchResult?
      private def fetch_one(fetch, node, err:)
        result = fetch.call(Proto::V1::FetchRequest.new(node:))
        log(err, level: 'info', node: node.name, message: 'fetched')
        result
      rescue StandardError => e
        # One unreachable or misbehaving device must not stop the others.
        log(err, level: 'error', node: node.name, error: e.class.name, message: e.message)
        nil
      end

      # @param err [IO] log destination
      # @param fields [Hash{Symbol => String, nil}] log fields
      # @return [void]
      #: (IO err, **String? fields) -> void
      private def log(err, **fields)
        @lock.synchronize { err.puts(JSON.generate(fields)) }
      end
    end
  end
end
