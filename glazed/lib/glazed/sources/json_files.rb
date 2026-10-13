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
      class InvalidFile < Glazed::Error; end

      # Node fields merged key by key with defaults.
      MAP_FIELDS = %w[params secrets].freeze #: Array[String]

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
      # @raise [InvalidFile] when the file is malformed or a node is incomplete
      #: (String path) -> Array[Proto::V1::Node]
      private def load_file(path)
        json = File.read(path)
        ProtoJson.load(Proto::V1::InventoryFile, json)
        document = JSON.parse(json) #: Hash[String, untyped]
        defaults = document.fetch('defaults', {}) #: Hash[String, untyped]
        nodes = document.fetch('nodes', []) #: Array[Hash[String, untyped]]
        nodes.map { |attributes| build_node(merge(defaults, attributes), path) }
      rescue Google::Protobuf::ParseError, JSON::ParserError => e
        raise InvalidFile, "#{path}: #{e.message}"
      end

      # @param defaults [Hash{String => Object}] default node attributes
      # @param attributes [Hash{String => Object}] node attributes
      # @return [Hash{String => Object}] attributes with defaults applied
      #: (Hash[String, untyped] defaults, Hash[String, untyped] attributes) -> Hash[String, untyped]
      private def merge(defaults, attributes)
        defaults.merge(attributes) do |key, default, value|
          MAP_FIELDS.include?(key) ? default.merge(value) : value
        end
      end

      # @param attributes [Hash{String => Object}] merged node attributes
      # @param path [String] file the node came from
      # @return [Proto::V1::Node] the node
      # @raise [InvalidFile] when the name or dialect is missing
      #: (Hash[String, untyped] attributes, String path) -> Proto::V1::Node
      private def build_node(attributes, path)
        node = ProtoJson.load(Proto::V1::Node, JSON.generate(attributes))
        raise InvalidFile, "#{path}: a node has no name" if node.name.empty?
        raise InvalidFile, "#{path}: node #{node.name.inspect} has no dialect" if node.dialect.empty?

        node
      end
    end
  end
end
