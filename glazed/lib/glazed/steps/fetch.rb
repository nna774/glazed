# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/collector'
require 'glazed/proto'
require 'glazed/steps'
require 'glazed/storages'

module Glazed
  module Steps
    # Collects one node's configuration and stores it unredacted.
    #
    # @example
    #   fetch = Glazed::Steps::Fetch.new(storage: raw_storage)
    #   result = fetch.call(Glazed::Proto::V1::FetchRequest.new(node:))
    class Fetch
      # @param storage [Storages::Base] storage for raw configuration
      # @param timeout [Numeric] seconds to wait for each expected device output
      #: (storage: Storages::Base, ?timeout: Numeric) -> void
      def initialize(storage:, timeout: CliSession::DEFAULT_TIMEOUT)
        @storage = storage #: Storages::Base
        @timeout = timeout #: Numeric
      end

      # @return [Storages::Base] storage for raw configuration
      #: Storages::Base
      attr_reader :storage

      # @param request [Proto::V1::FetchRequest] node to collect from
      # @return [Proto::V1::FetchResult] the node and the location of its raw configuration
      # @raise [ArgumentError] when the request has no node
      # @raise [Glazed::Error] when collecting or storing fails
      #: (Proto::V1::FetchRequest request) -> Proto::V1::FetchResult
      def call(request)
        node = request.node or raise ArgumentError, 'fetch request has no node'
        config = collect(node)
        raw = storage.write(key: Storages.key_for(node), content: config, message: "#{node.name}: fetch")
        Proto::V1::FetchResult.new(node:, raw:)
      end

      # @param node [Proto::V1::Node] node to collect from
      # @return [String] its configuration
      #: (Proto::V1::Node node) -> String
      private def collect(node) = Collector.new(node:, timeout: @timeout).call
    end
  end
end
