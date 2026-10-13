# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'glazed'
require 'glazed/proto'

module Glazed
  module Storages
    # Store of configuration files addressed by slash-separated keys, such as
    # "core/rt1". Subclasses implement {.from_proto}, {#write_all} and {#read}.
    class Base
      # Raised for a key that is empty or could escape the storage root.
      class InvalidKey < Glazed::Error; end

      #: type file = [String, String]

      # Builds a storage from its settings message.
      #
      # @param settings [Google::Protobuf::MessageExts] backend settings from {Proto::V1::StorageConfig}
      # @return [Base] the storage
      #: (Google::Protobuf::MessageExts settings) -> Base
      def self.from_proto(settings) = raise NotImplementedError

      # Writes one file.
      #
      # @param key [String] file key
      # @param content [String] file content
      # @param message [String] description of the change, such as a commit message
      # @return [Proto::V1::Pointer] location of the written content
      # @raise [InvalidKey] for an unsafe key
      #: (key: String, content: String, message: String) -> Proto::V1::Pointer
      def write(key:, content:, message:)
        write_all([[key, content]], message:).fetch(0)
      end

      # Writes several files as one change where the storage supports it.
      #
      # @param files [Array<Array(String, String)>] keys and contents
      # @param message [String] description of the change, such as a commit message
      # @return [Array<Proto::V1::Pointer>] locations, in the order of files
      # @raise [InvalidKey] for an unsafe key
      #: (Array[Base::file] files, message: String) -> Array[Proto::V1::Pointer]
      def write_all(files, message:) = raise NotImplementedError

      # Reads content written earlier.
      #
      # @param pointer [Proto::V1::Pointer] location returned by a write
      # @return [String] the content
      #: (Proto::V1::Pointer pointer) -> String
      def read(pointer) = raise NotImplementedError

      # @param key [String] key to check
      # @return [String] the key
      # @raise [InvalidKey] when the key is empty, absolute, or has empty, "." or ".." segments
      #: (String key) -> String
      private def validate_key(key)
        segments = key.split('/', -1)
        raise InvalidKey, "invalid storage key #{key.inspect}" if segments.empty? || segments.any? { ['', '.', '..'].include?(it) }

        key
      end
    end
  end
end
