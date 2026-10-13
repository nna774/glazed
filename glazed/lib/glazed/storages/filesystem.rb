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
          pointer = Proto::V1::Pointer.new(filesystem: Proto::V1::FilesystemLocation.new(path: key, sha256: Digest::SHA256.hexdigest(content)))
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
        location = pointer.filesystem or raise ArgumentError, "not a filesystem pointer: #{pointer.location.inspect}"
        content = ::File.read(::File.join(path, validate_key(location.path)))
        unless Digest::SHA256.hexdigest(content) == location.sha256
          raise StaleContent, "#{location.path} in #{path} no longer holds the content written"
        end

        content
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
