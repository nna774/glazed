# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'aws-sdk-ssm'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/secret'
require 'glazed/secrets'
require 'glazed/durations'

module Glazed
  # Namespace of secret sources; glazed-aws adds {Ssm}.
  module Secrets
    # AWS Systems Manager Parameter Store parameter, decrypted when it is a
    # SecureString. A fetched value is reused for cache_seconds, so nodes of a
    # batch sharing a password fetch it once per resolver.
    #
    # @example
    #   Glazed::Secrets::Ssm.new(name: '/glazed/backup/password').value
    class Ssm < Base
      # Seconds a fetched value is reused when the settings set none.
      DEFAULT_CACHE_SECONDS = 300 #: Integer

      # @param name [String] name or ARN of the parameter
      # @param region [String, nil] region of the parameter; the SDK default when nil
      # @param cache_seconds [Numeric] seconds a fetched value is reused
      # @param client [Aws::SSM::Client, nil] client to use instead of building one
      # @param clock [Proc] returns monotonic seconds
      #: (name: String, ?region: String?, ?cache_seconds: Numeric, ?client: ::Aws::SSM::Client?, ?clock: ^() -> Float) -> void
      def initialize(name:, region: nil, cache_seconds: DEFAULT_CACHE_SECONDS, client: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f })
        super()
        @name = name #: String
        @region = region #: String?
        @cache_seconds = cache_seconds #: Numeric
        @client = client #: ::Aws::SSM::Client?
        @clock = clock #: ^() -> Float
        @value = nil #: String?
        @fetched_at = nil #: Float?
        @lock = Mutex.new #: Thread::Mutex
      end

      # Builds a source from {Proto::V1::SsmParameter}.
      #
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::SsmParameter}
      # @return [Ssm] the source
      # @raise [Must::Violation] when settings is another message
      #: (Google::Protobuf::MessageExts settings) -> Ssm
      def self.from_proto(settings)
        ssm = Must.be_a(settings, Proto::V1::SsmParameter)
        new(
          name: ssm.name,
          region: ssm.region.empty? ? nil : ssm.region,
          cache_seconds: Durations.seconds(ssm.cache, DEFAULT_CACHE_SECONDS),
        )
      end

      # @return [String] name or ARN of the parameter
      #: String
      attr_reader :name

      # @return [String] the parameter value, fetched again once cache_seconds have passed
      # @raise [Secret::Unavailable] when the parameter or its version does not exist
      # @raise [Aws::SSM::Errors::ServiceError] when the request fails otherwise, such as for lack of permission
      #: () -> String
      def value
        @lock.synchronize do
          now = @clock.call
          cached = @value
          fetched_at = @fetched_at
          return cached if cached && fetched_at && now - fetched_at < @cache_seconds.to_f

          fetch.tap do |fetched|
            @value = fetched
            @fetched_at = now
          end
        end
      end

      # @return [String] the current value
      # @raise [Secret::Unavailable] when the parameter or its version does not exist
      #: () -> String
      private def fetch
        parameter = client.get_parameter(name:, with_decryption: true).parameter
        parameter&.value or raise Secret::Unavailable, "SSM parameter #{name} has no value"
      rescue ::Aws::SSM::Errors::ParameterNotFound, ::Aws::SSM::Errors::ParameterVersionNotFound => e
        raise Secret::Unavailable, "SSM parameter #{name}: #{e.message}"
      end

      # @return [Aws::SSM::Client] the client
      #: () -> ::Aws::SSM::Client
      private def client
        @client ||= @region ? ::Aws::SSM::Client.new(region: @region) : ::Aws::SSM::Client.new
      end
    end
  end
end
