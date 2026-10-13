# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'digest'
require 'fileutils'
require 'securerandom'
require 'glazed'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/storages/base'

module Glazed
  module Storages
    # Local directory holding the latest content of each key, for scripts and
    # tools that read plain files. It keeps no history.
    #
    # @example
    #   storage = Glazed::Storages::Filesystem.new(path: '/var/lib/glazed/latest')
    #   storage.write(key: 'core/rt1', content: config, message: 'rt1')
    class Filesystem < Base
      # Raised when a file no longer holds the content its pointer names.
      class StaleContent < Glazed::Error; end

      # @param path [String] directory holding the files, created when missing
      #: (path: String) -> void
      def initialize(path:)
        super()
        @path = path #: String
      end

      # Builds a storage from {Proto::V1::FilesystemStorage}.
      #
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::FilesystemStorage}
      # @return [Filesystem] the storage
      # @raise [Must::Violation] when settings is another message
      #: (Google::Protobuf::MessageExts settings) -> Filesystem
      def self.from_proto(settings)
        filesystem = Must.be_a(settings, Proto::V1::FilesystemStorage)
        new(path: filesystem.path)
      end

      # @return [String] directory holding the files
      #: String
      attr_reader :path

      # Writes each changed file in place. A file is replaced atomically, so
      # readers see either the old or the new content.
      #
      # @param files [Array<Array(String, String)>] keys and contents
      # @param message [Proc] builds a description of the change, unused
      # @return [Array<WriteResult>] the content's location and digest, and whether the file changed
      # @raise [InvalidKey] for an unsafe key
      #: (Array[Base::file] files, message: Base::message_builder) -> Array[WriteResult]
      def write_all(files, message:)
        files.each { |key, _| validate_key(key) }
        files.map do |key, content|
          file = ::File.join(path, key)
          changed = !(::File.file?(file) && ::File.binread(file) == content.b)
          replace(file, content) if changed
          pointer = pointer_to(Proto::V1::FilesystemLocation.new(path: key, sha256: Digest::SHA256.hexdigest(content)))
          WriteResult.new(pointer:, changed:)
        end
      end

      # Reads the file a pointer names.
      #
      # @param pointer [Proto::V1::Pointer] pointer with a filesystem location
      # @return [String] the content
      # @raise [ArgumentError] when the pointer is not a filesystem location
      # @raise [StaleContent] when the file has been rewritten with other content since
      # @raise [Errno::ENOENT] when the file is gone
      #: (Proto::V1::Pointer pointer) -> String
      def read(pointer)
        location = location_of(pointer, Proto::V1::FilesystemLocation)
        content = ::File.read(::File.join(path, validate_key(location.path)))
        unless Digest::SHA256.hexdigest(content) == location.sha256
          raise StaleContent, "#{location.path} in #{path} no longer holds the content written"
        end

        content
      end

      # @return [Boolean] true; versions are content digests
      #: () -> bool
      def conditional? = true

      # @param key [String] file key
      # @return [String, nil] SHA-256 of the file, or nil when it is missing
      # @raise [InvalidKey] for an unsafe key
      #: (String key) -> String?
      def version_of(key) = read_versioned(key)&.version

      # @param key [String] file key
      # @return [Versioned, nil] the content and its SHA-256, or nil when the file is missing
      # @raise [InvalidKey] for an unsafe key
      #: (String key) -> Versioned?
      def read_versioned(key)
        content = ::File.binread(::File.join(path, validate_key(key)))
        Versioned.new(content:, version: Digest::SHA256.hexdigest(content))
      rescue Errno::ENOENT
        nil
      end

      # Replaces the file while holding an exclusive lock on a sibling lock
      # file, which every conditional writer of the key takes.
      #
      # @param key [String] file key
      # @param content [String] new content
      # @param expected_version [String, nil] SHA-256 read earlier; nil to create a missing file only
      # @return [String] SHA-256 of the content
      # @raise [Conflict] when the file holds other content
      # @raise [InvalidKey] for an unsafe key
      #: (key: String, content: String, expected_version: String?) -> String
      def write_if(key:, content:, expected_version:)
        file = ::File.join(path, validate_key(key))
        FileUtils.mkdir_p(::File.dirname(file))
        ::File.open(::File.join(::File.dirname(file), ".#{::File.basename(file)}.lock"), ::File::RDWR | ::File::CREAT, 0o644) do |lock|
          lock.flock(::File::LOCK_EX)
          current = version_of(key)
          raise Conflict, "#{key} in #{path} is at #{current || 'nothing'}, not #{expected_version || 'nothing'}" unless current == expected_version

          replace(file, content)
        end
        Digest::SHA256.hexdigest(content)
      end

      # @param file [String] file to replace
      # @param content [String] new content
      # @return [void]
      #: (String file, String content) -> void
      private def replace(file, content)
        dir = ::File.dirname(file)
        FileUtils.mkdir_p(dir)
        temporary = ::File.join(dir, ".#{::File.basename(file)}.#{SecureRandom.hex(8)}.tmp")
        ::File.binwrite(temporary, content)
        ::File.rename(temporary, file)
      ensure
        ::File.unlink(temporary) if temporary && ::File.exist?(temporary)
      end
    end
  end
end
