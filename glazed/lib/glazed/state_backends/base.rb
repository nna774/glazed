# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'glazed'
require 'glazed/proto'

module Glazed
  module StateBackends
    # Store of {Proto::V1::NodeSchedule} records, one per workflow and node.
    # Records change only through read-modify-write blocks, which a backend may
    # run more than once when another process changed the records meanwhile,
    # so a block must compute its result from the record it is given alone.
    # Subclasses implement {.from_proto}, {#update_all}, {#list_due} and {#list}.
    class Base
      #: type updater = ^(String node, Proto::V1::NodeSchedule? record) -> Proto::V1::NodeSchedule?

      # Builds a state backend from its settings message.
      #
      # @param settings [Google::Protobuf::MessageExts] backend settings from {Proto::V1::StateBackendConfig}
      # @param context [StepContext] configured storages, and where progress is reported
      # @return [Base] the state backend
      #: (Google::Protobuf::MessageExts settings, context: StepContext) -> Base
      def self.from_proto(settings, context:) = raise NotImplementedError

      # Replaces the records of nodes with what the block returns.
      #
      # @param workflow [String] workflow name
      # @param nodes [Array<String>] node names
      # @yieldparam node [String] node name
      # @yieldparam record [Proto::V1::NodeSchedule, nil] the current record, or nil when there is none
      # @yieldreturn [Proto::V1::NodeSchedule, nil] the new record, or nil to delete it
      # @return [Hash{String => Proto::V1::NodeSchedule}] records held afterwards, by node name
      #: (String workflow, Array[String] nodes) { (String node, Proto::V1::NodeSchedule? record) -> Proto::V1::NodeSchedule? } -> Hash[String, Proto::V1::NodeSchedule]
      def update_all(workflow, nodes, &) = raise NotImplementedError

      # Replaces the record of one node with what the block returns.
      #
      # @param workflow [String] workflow name
      # @param node [String] node name
      # @yieldparam record [Proto::V1::NodeSchedule, nil] the current record, or nil when there is none
      # @yieldreturn [Proto::V1::NodeSchedule, nil] the new record, or nil to delete it
      # @return [Proto::V1::NodeSchedule, nil] the record held afterwards
      #: (String workflow, String node) { (Proto::V1::NodeSchedule? record) -> Proto::V1::NodeSchedule? } -> Proto::V1::NodeSchedule?
      def update(workflow, node, &block)
        update_all(workflow, [node]) { |_node, record| block.call(record) }[node]
      end

      # Records due at or before a time and not leased to an orchestrator.
      #
      # @param workflow [String] workflow name
      # @param now [Time] the time; a lease ending at or before it has expired
      # @param limit [Integer, nil] records returned at most; all when nil
      # @return [Array<Proto::V1::NodeSchedule>] the records, earliest due first
      #: (String workflow, now: Time, ?limit: Integer?) -> Array[Proto::V1::NodeSchedule]
      def list_due(workflow, now:, limit: nil) = raise NotImplementedError

      # @param workflow [String] workflow name
      # @return [Array<Proto::V1::NodeSchedule>] every record of the workflow, by node name
      #: (String workflow) -> Array[Proto::V1::NodeSchedule]
      def list(workflow) = raise NotImplementedError

      # Releases resources held by the backend.
      #
      # @return [void]
      #: () -> void
      def close; end
    end
  end
end
