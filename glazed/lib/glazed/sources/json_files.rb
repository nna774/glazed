# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'glazed'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/proto_json'
require 'glazed/sources'
require 'glazed/sources/base'
require 'glazed/validation'

module Glazed
  module Sources
    # Inventory read from ProtoJSON files of {Proto::V1::InventoryFile}.
    #
    # Each file's `defaults` fill fields its nodes leave unset. The `params`
    # and `secrets` maps are merged key by key.
    #
    # @example
    #   Glazed::Sources::JsonFiles.new(paths: ['inventory/*.json']).nodes
    class JsonFiles < Base
      # Raised when a file is not a valid inventory file.
      InvalidFile = Base::InvalidInventory

      # @param paths [Array<String>] file paths or glob patterns
      #: (paths: Array[String]) -> void
      def initialize(paths:)
        super()
        @paths = paths #: Array[String]
      end

      # Builds a provider from {Proto::V1::JsonFilesInventory}.
      #
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::JsonFilesInventory}
      # @return [JsonFiles] the provider
      # @raise [Must::Violation] when settings is another message
      #: (Google::Protobuf::MessageExts settings) -> JsonFiles
      def self.from_proto(settings)
        new(paths: Must.be_a(settings, Proto::V1::JsonFilesInventory).paths.to_a)
      end

      # @return [Array<String>] file paths or glob patterns
      #: Array[String]
      attr_reader :paths

      # Reads every file and returns its nodes.
      #
      # @return [Array<Proto::V1::Node>] nodes in file order
      # @raise [InvalidFile] when a file is malformed or a node lacks a name or dialect
      # @raise [Sources::DuplicateNode] when a node name appears twice
      # @raise [Errno::ENOENT] when a literal path does not exist
      #: () -> Array[Proto::V1::Node]
      def nodes
        origins = {} #: Hash[String, String]
        files.flat_map do |path|
          load_file(path).each do |node|
            if (other = origins[node.name])
              raise DuplicateNode, "node #{node.name.inspect} is defined in both #{other} and #{path}"
            end

            origins[node.name] = path
          end
        end
      end

      # @return [String] the path patterns
      #: () -> String
      def description = "json_files #{paths.join(', ')}"

      # @return [Array<String>] files matched by {#paths}, in a stable order
      #: () -> Array[String]
      private def files
        paths.flat_map do |pattern|
          matches = Dir.glob(pattern).sort
          matches.empty? && !pattern.match?(/[*?\[{]/) ? [pattern] : matches
        end.uniq
      end

      # @param path [String] inventory file
      # @return [Array<Proto::V1::Node>] nodes with defaults applied
      # @raise [InvalidFile] when the file is malformed
      # @raise [InvalidMessage] when the file breaks the rules of its schema
      #: (String path) -> Array[Proto::V1::Node]
      private def load_file(path)
        json = File.read(path)
        Validation.validate!(ProtoJson.load(Proto::V1::InventoryFile, json), origin: path)
        document = JSON.parse(json) #: Hash[String, untyped]
        nodes_from(document, origin: path)
      rescue Google::Protobuf::ParseError, JSON::ParserError => e
        raise InvalidFile, "#{path}: #{e.message}"
      end
    end
  end
end
