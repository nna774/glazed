# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'base64'
require 'digest'
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
      # Content type of stored objects. No charset: devices do not all use UTF-8.
      CONTENT_TYPE = 'text/plain' #: String
      # Attempts at writing an object that other writers keep changing.
      MAX_ATTEMPTS = 3 #: Integer

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
      #: (Google::Protobuf::MessageExts settings) -> S3
      def self.from_proto(settings)
        s3 = Must.be_a(settings, Proto::V1::S3Storage)
        new(bucket: s3.bucket, prefix: s3.prefix, region: s3.region.empty? ? nil : s3.region)
      end

      # @return [String] bucket name
      #: String
      attr_reader :bucket
      # @return [String] prefix prepended to every key
      #: String
      attr_reader :prefix

      # Puts one object per changed file, compared by SHA-256 checksum. Puts are
      # conditional on the object checked, so a concurrent writer is never
      # overwritten unseen. S3 has no multi-object transaction, so the message
      # is not recorded.
      #
      # @param files [Array<Array(String, String)>] keys and contents
      # @param message [Proc] builds a description of the change, unused
      # @return [Array<WriteResult>] the object version holding each file, and whether the file changed
      # @raise [InvalidKey] for an unsafe key
      # @raise [Aws::S3::Errors::ServiceError] when a request fails, or the object keeps changing under concurrent writers
      #: (Array[Base::file] files, message: Base::message_builder) -> Array[WriteResult]
      def write_all(files, message:)
        files.each { |key, _| validate_key(key) }
        files.map { |key, content| write_object("#{prefix}#{key}", content) }
      end

      # Reads the object version a pointer names.
      #
      # @param pointer [Proto::V1::Pointer] pointer with an s3 location
      # @return [String] the content
      # @raise [ArgumentError] when the pointer is not an s3 location
      # @raise [Aws::S3::Errors::ServiceError] when the object or version does not exist
      #: (Proto::V1::Pointer pointer) -> String
      def read(pointer)
        location = location_of(pointer, Proto::V1::S3Location)
        response = if location.version_id.empty?
          client.get_object(bucket: location.bucket, key: location.key)
        else
          client.get_object(bucket: location.bucket, key: location.key, version_id: location.version_id)
                   end
        response.body.read.to_s
      end

      # @return [Boolean] true; versions are ETags
      #: () -> bool
      def conditional? = true

      # @param key [String] file key
      # @return [String, nil] ETag of the object, or nil when it is missing
      # @raise [InvalidKey] for an unsafe key
      # @raise [Aws::S3::Errors::ServiceError] for errors other than not found
      #: (String key) -> String?
      def version_of(key) = head("#{prefix}#{validate_key(key)}")&.etag

      # @param key [String] file key
      # @return [Versioned, nil] the content and its ETag, or nil when the object is missing
      # @raise [InvalidKey] for an unsafe key
      # @raise [Aws::S3::Errors::ServiceError] for errors other than not found
      #: (String key) -> Versioned?
      def read_versioned(key)
        response = client.get_object(bucket:, key: "#{prefix}#{validate_key(key)}")
        Versioned.new(content: response.body.read.to_s, version: response.etag)
      rescue ::Aws::S3::Errors::NoSuchKey
        nil
      end

      # Puts the object with If-Match on the expected ETag, or If-None-Match
      # when it must not exist yet.
      #
      # @param key [String] file key
      # @param content [String] new content
      # @param expected_version [String, nil] ETag read earlier; nil to create a missing object only
      # @return [String] ETag of the written object
      # @raise [Conflict] when the object holds another version
      # @raise [InvalidKey] for an unsafe key
      # @raise [Aws::S3::Errors::ServiceError] when the request fails otherwise
      #: (key: String, content: String, expected_version: String?) -> String
      def write_if(key:, content:, expected_version:)
        object_key = "#{prefix}#{validate_key(key)}"
        checksum = Base64.strict_encode64(Digest::SHA256.digest(content))
        response = if expected_version
          client.put_object(bucket:, key: object_key, body: content, checksum_sha256: checksum, if_match: expected_version)
        else
          client.put_object(bucket:, key: object_key, body: content, checksum_sha256: checksum, if_none_match: '*')
                   end
        response.etag
      rescue ::Aws::S3::Errors::PreconditionFailed, ::Aws::S3::Errors::ConditionalRequestConflict => e
        raise Conflict, "s3://#{bucket}/#{object_key} changed: #{e.message}"
      end

      # @param key [String] object key
      # @param content [String] content
      # @return [WriteResult] the version holding the content, and whether it was written
      # @raise [Aws::S3::Errors::ServiceError] when a request fails or attempts run out
      #: (String key, String content) -> WriteResult
      private def write_object(key, content)
        checksum = Base64.strict_encode64(Digest::SHA256.digest(content))
        attempts = 0
        begin
          attempts += 1
          current = head(key)
          if current && current.checksum_sha256 == checksum
            return WriteResult.new(pointer: pointer(key, current.version_id), changed: false)
          end

          response = if current
            client.put_object(bucket:, key:, body: content, content_type: CONTENT_TYPE, checksum_sha256: checksum, if_match: current.etag)
          else
            client.put_object(bucket:, key:, body: content, content_type: CONTENT_TYPE, checksum_sha256: checksum, if_none_match: '*')
                     end
        rescue ::Aws::S3::Errors::PreconditionFailed, ::Aws::S3::Errors::ConditionalRequestConflict
          # Another writer changed the object after it was checked.
          retry if attempts < MAX_ATTEMPTS
          raise
        end
        WriteResult.new(pointer: pointer(key, response.version_id), changed: true)
      end

      # @param key [String] object key
      # @return [Aws::S3::Types::HeadObjectOutput, nil] the current object with its checksum, or nil when absent
      # @raise [Aws::S3::Errors::ServiceError] for errors other than not found
      #: (String key) -> ::Aws::S3::Types::HeadObjectOutput?
      private def head(key)
        client.head_object(bucket:, key:, checksum_mode: 'ENABLED')
      rescue ::Aws::S3::Errors::NotFound
        nil
      end

      # @param key [String] object key
      # @param version_id [String, nil] object version; nil for an unversioned bucket
      # @return [Proto::V1::Pointer] pointer to the version
      #: (String key, String? version_id) -> Proto::V1::Pointer
      private def pointer(key, version_id)
        pointer_to(Proto::V1::S3Location.new(bucket:, key:, version_id: version_id.to_s))
      end

      # @return [Aws::S3::Client] the injected client, or one built on first use
      #: () -> ::Aws::S3::Client
      private def client
        @client ||= @region ? ::Aws::S3::Client.new(region: @region) : ::Aws::S3::Client.new
      end
    end
  end
end
