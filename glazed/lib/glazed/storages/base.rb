# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'glazed'
require 'glazed/must'
require 'glazed/proto'

module Glazed
  module Storages
    # Store of configuration files addressed by slash-separated keys, such as
    # "core/rt1". Subclasses implement {.from_proto}, {#write_all} and {#read}.
    class Base
      # Raised for a key that is empty or could escape the storage root.
      class InvalidKey < Glazed::Error; end

      #: type file = [String, String]
      #: type message_builder = ^(Array[String] changed_keys) -> String

      # Outcome of writing one file.
      class WriteResult
        # @param pointer [Proto::V1::Pointer] location holding the content
        # @param changed [Boolean] whether the content differs from what the key held before
        #: (pointer: Proto::V1::Pointer, changed: bool) -> void
        def initialize(pointer:, changed:)
          @pointer = pointer #: Proto::V1::Pointer
          @changed = changed #: bool
        end

        # @return [Proto::V1::Pointer] location holding the content; the existing one when unchanged
        #: Proto::V1::Pointer
        attr_reader :pointer

        # @return [Boolean] whether the content differs from what the key held before
        #: () -> bool
        def changed? = @changed
      end

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
      # @return [WriteResult] where the content is and whether it changed
      # @raise [InvalidKey] for an unsafe key
      #: (key: String, content: String, message: String) -> WriteResult
      def write(key:, content:, message:)
        write_all([[key, content]], message: ->(_changed_keys) { message }).fetch(0)
      end

      # Writes several files as one change where the storage supports it. Files
      # whose content equals what their key holds are not written again.
      #
      # @param files [Array<Array(String, String)>] keys and contents
      # @param message [Proc] builds the description of the change, such as a
      #   commit message, from the keys whose content changed; not called when none did
      # @return [Array<WriteResult>] results, in the order of files
      # @raise [InvalidKey] for an unsafe key
      #: (Array[Base::file] files, message: Base::message_builder) -> Array[WriteResult]
      def write_all(files, message:) = raise NotImplementedError

      # Reads content written earlier.
      #
      # @param pointer [Proto::V1::Pointer] location returned by a write
      # @return [String] the content
      #: (Proto::V1::Pointer pointer) -> String
      def read(pointer) = raise NotImplementedError

      # Wraps a location in a pointer.
      #
      # @param location [Google::Protobuf::MessageExts] storage-specific location
      # @return [Proto::V1::Pointer] the pointer
      #: (Google::Protobuf::MessageExts location) -> Proto::V1::Pointer
      private def pointer_to(location) = Proto::V1::Pointer.new(location: Google::Protobuf::Any.pack(location))

      # Unwraps the location of a pointer.
      #
      # @param pointer [Proto::V1::Pointer] the pointer
      # @param location_class [Class] location message this storage writes
      # @return [Google::Protobuf::MessageExts] the location
      # @raise [ArgumentError] when the pointer holds another kind of location
      #: [L] (Proto::V1::Pointer pointer, Class[L] location_class) -> L
      private def location_of(pointer, location_class)
        any = pointer.location or raise ArgumentError, 'pointer has no location'
        location = any.unpack(location_class) or raise ArgumentError, "#{self.class.name} cannot read a pointer to #{any.type_name}"
        Must.be_a(location, location_class)
      end

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
