# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'digest'
require 'glazed'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/storages/base'

module Glazed
  module Storages
    # Memory of the running process, for content that must not be persisted,
    # such as raw configuration when only the redacted copy is kept. Content
    # lives until the process exits, so only steps of the same run can read it.
    #
    # @example Storage config
    #   {"memory": {}}
    class Memory < Base
      # Raised when a pointer names content this process does not hold.
      class MissingContent < Glazed::Error; end

      #: () -> void
      def initialize
        super
        @contents = {} #: Hash[String, String]
        @latest = {} #: Hash[String, String]
        @lock = Mutex.new #: Thread::Mutex
      end

      # Builds a storage from {Proto::V1::MemoryStorage}.
      #
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::MemoryStorage}
      # @return [Memory] the storage
      # @raise [Must::Violation] when settings is another message
      #: (Google::Protobuf::MessageExts settings) -> Memory
      def self.from_proto(settings)
        Must.be_a(settings, Proto::V1::MemoryStorage)
        new
      end

      # Keeps each file in memory. A file is changed unless this process
      # already wrote the same content under its key.
      #
      # @param files [Array<Array(String, String)>] keys and contents
      # @param message [Proc] builds a description of the change, unused
      # @return [Array<WriteResult>] the content's key and digest, and whether it changed
      # @raise [InvalidKey] for an unsafe key
      #: (Array[Base::file] files, message: Base::message_builder) -> Array[WriteResult]
      def write_all(files, message:)
        files.each { |key, _| validate_key(key) }
        files.map do |key, content|
          sha256 = Digest::SHA256.hexdigest(content)
          changed = @lock.synchronize do
            @contents[sha256] = content.dup.freeze
            previous = @latest[key]
            @latest[key] = sha256
            previous != sha256
          end
          WriteResult.new(pointer: pointer_to(Proto::V1::MemoryLocation.new(key:, sha256:)), changed:)
        end
      end

      # Reads content written earlier by this process.
      #
      # @param pointer [Proto::V1::Pointer] pointer with a memory location
      # @return [String] the content
      # @raise [ArgumentError] when the pointer is not a memory location
      # @raise [MissingContent] when this process did not write the content, for
      #   example when the pointer comes from another process
      #: (Proto::V1::Pointer pointer) -> String
      def read(pointer)
        location = location_of(pointer, Proto::V1::MemoryLocation)
        content = @lock.synchronize { @contents[location.sha256] }
        content or raise MissingContent, "#{location.key} is not held in this process; memory storage only works within one glazed run"
      end
    end
  end
end
