# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'aws-sdk-states'
require 'glazed/aws'

module Glazed
  module Aws
    # Tells whether the Step Functions execution holding the waiter record
    # still runs, so a waiter that failed or was stopped does not hold off
    # other executions until its record expires. Tokens other than execution
    # ARNs are presumed to run.
    #
    # @example
    #   liveness = Glazed::Aws::ExecutionLiveness.new
    #   Glazed::Coordinator.new(settings:, backend:, waiter_alive: ->(token) { liveness.call(token) })
    class ExecutionLiveness
      # Statuses of an execution that may still wake.
      LIVE_STATUSES = %w[RUNNING PENDING_REDRIVE].freeze #: Array[String]

      # @param client [Aws::States::Client, nil] client to use instead of building one per region
      #: (?client: ::Aws::States::Client?) -> void
      def initialize(client: nil)
        @client = client #: ::Aws::States::Client?
        @clients = {} #: Hash[String, ::Aws::States::Client]
      end

      # @param token [String] the waiter's token, the ARN of its execution
      # @return [Boolean] false when the execution is known to have ended
      # @raise [Aws::States::Errors::ServiceError] when the request fails otherwise, such as for lack of permission
      #: (String token) -> bool
      def call(token)
        _arn, _partition, service, region, _account, resource = token.split(':', 6)
        return true unless service == 'states' && region && resource&.start_with?('execution:')

        LIVE_STATUSES.include?(client(region).describe_execution(execution_arn: token).status)
      rescue ::Aws::States::Errors::ExecutionDoesNotExist
        false
      end

      # @param region [String] region of the execution
      # @return [Aws::States::Client] the client
      #: (String region) -> ::Aws::States::Client
      private def client(region)
        @client || (@clients[region] ||= ::Aws::States::Client.new(region:))
      end
    end
  end
end
