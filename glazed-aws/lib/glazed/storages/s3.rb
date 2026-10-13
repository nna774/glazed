# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'aws-sdk-s3'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/storages/base'

module Glazed
  # Namespace of storage implementations; glazed-aws adds {S3}.
  module Storages
    # Amazon S3 bucket. Each file is one object under the prefix; with bucket
    # versioning, pointers name the exact object version written.
    #
    # @example
    #   storage = Glazed::Storages::S3.new(bucket: 'netconf', prefix: 'raw/')
    #   storage.write(key: 'core/rt1', content: config, message: 'rt1')
    class S3 < Base
      # Content type of stored objects.
      CONTENT_TYPE = 'text/plain; charset=utf-8' #: String

      # @param bucket [String] bucket name
      # @param prefix [String] prefix prepended to every key
      # @param region [String, nil] bucket region; the SDK default when nil
      # @param client [Aws::S3::Client, nil] client to use instead of building one
      #: (bucket: String, ?prefix: String, ?region: String?, ?client: ::Aws::S3::Client?) -> void
      def initialize(bucket:, prefix: '', region: nil, client: nil)
        super()
        @bucket = bucket #: String
        @prefix = prefix #: String
        @region = region #: String?
        @client = client #: ::Aws::S3::Client?
      end

      # Builds a storage from {Proto::V1::S3Storage}.
      #
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::S3Storage}
      # @return [S3] the storage
      # @raise [Must::Violation] when settings is another message
      # @raise [ArgumentError] when the bucket is missing
      #: (Google::Protobuf::MessageExts settings) -> S3
      def self.from_proto(settings)
        s3 = Must.be_a(settings, Proto::V1::S3Storage)
        raise ArgumentError, 's3 storage needs a bucket' if s3.bucket.empty?

        new(bucket: s3.bucket, prefix: s3.prefix, region: s3.region.empty? ? nil : s3.region)
      end

      # @return [String] bucket name
      #: String
      attr_reader :bucket
      # @return [String] prefix prepended to every key
      #: String
      attr_reader :prefix

      # Puts one object per file. S3 has no multi-object transaction, so the
      # message is not recorded.
      #
      # @param files [Array<Array(String, String)>] keys and contents
      # @param message [String] description of the change, unused
      # @return [Array<Proto::V1::Pointer>] pointers to the written object versions
      # @raise [InvalidKey] for an unsafe key
      # @raise [Aws::S3::Errors::ServiceError] when a put fails
      #: (Array[Base::file] files, message: String) -> Array[Proto::V1::Pointer]
      def write_all(files, message:)
        files.each { |key, _| validate_key(key) }
        files.map do |key, content|
          object_key = "#{prefix}#{key}"
          response = client.put_object(bucket:, key: object_key, body: content, content_type: CONTENT_TYPE)
          location = Proto::V1::S3Location.new(bucket:, key: object_key, version_id: response.version_id.to_s)
          Proto::V1::Pointer.new(s3: location)
        end
      end

      # Reads the object version a pointer names.
      #
      # @param pointer [Proto::V1::Pointer] pointer with an s3 location
      # @return [String] the content
      # @raise [ArgumentError] when the pointer is not an s3 location
      # @raise [Aws::S3::Errors::ServiceError] when the object or version does not exist
      #: (Proto::V1::Pointer pointer) -> String
      def read(pointer)
        location = pointer.s3 or raise ArgumentError, "not an s3 pointer: #{pointer.location.inspect}"
        response = if location.version_id.empty?
          client.get_object(bucket: location.bucket, key: location.key)
        else
          client.get_object(bucket: location.bucket, key: location.key, version_id: location.version_id)
                   end
        response.body.read.to_s
      end

      # @return [Aws::S3::Client] the injected client, or one built on first use
      #: () -> ::Aws::S3::Client
      private def client
        @client ||= @region ? ::Aws::S3::Client.new(region: @region) : ::Aws::S3::Client.new
      end
    end
  end
end
