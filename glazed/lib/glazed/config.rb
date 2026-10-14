# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'json'
require 'google/protobuf'
require 'glazed'
require 'glazed/proto'
require 'glazed/proto_json'
require 'glazed/validation'

module Glazed
  # Reads glazed configs ({Proto::V1::Config}).
  module Config
    # Reads a config file with {.parse}.
    #
    # @param path [String] config file
    # @return [Proto::V1::Config] the config
    # @raise [Glazed::Error] when `requires` is malformed, or the config does not decode
    # @raise [InvalidMessage] when the config breaks the rules of its schema
    # @raise [LoadError] when a required feature is missing
    #: (String path) -> Proto::V1::Config
    def self.load(path) = parse(::File.read(path), origin: path)

    # Decodes a config, first requiring the features its `requires` lists so
    # plugin settings types are known when it is decoded.
    #
    # @param json [String] ProtoJSON of {Proto::V1::Config}
    # @param origin [String] where the config comes from, for error messages
    # @return [Proto::V1::Config] the config
    # @raise [Glazed::Error] when `requires` is malformed, or the config does not decode
    # @raise [InvalidMessage] when the config breaks the rules of its schema
    # @raise [LoadError] when a required feature is missing
    #: (String json, origin: String) -> Proto::V1::Config
    def self.parse(json, origin:)
      document = JSON.parse(json) #: untyped
      requires = document.is_a?(Hash) ? document.fetch('requires', []) : []
      unless requires.is_a?(Array) && requires.all?(String)
        raise Glazed::Error, "#{origin}: requires must be a list of strings"
      end

      requires.each { require it }
      ProtoJson.load(Proto::V1::Config, json).tap { Validation.validate!(it, origin:) }
    rescue Google::Protobuf::ParseError, JSON::ParserError => e
      hint = e.message.include?('Type was not found') ? '; list the gem providing that plugin type in requires' : ''
      raise Glazed::Error, "#{origin}: #{e.message}#{hint}"
    end
  end
end
