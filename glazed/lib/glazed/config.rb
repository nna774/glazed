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
  # Reads glazed config files ({Proto::V1::Config}).
  module Config
    # Reads a config file, first requiring the features its `requires` lists
    # so plugin settings types are known when it is decoded.
    #
    # @param path [String] config file
    # @return [Proto::V1::Config] the config
    # @raise [Glazed::Error] when `requires` is malformed, or the config does not decode
    # @raise [InvalidMessage] when the config breaks the rules of its schema
    # @raise [LoadError] when a required feature is missing
    #: (String path) -> Proto::V1::Config
    def self.load(path)
      json = ::File.read(path)
      document = JSON.parse(json) #: untyped
      requires = document.is_a?(Hash) ? document.fetch('requires', []) : []
      unless requires.is_a?(Array) && requires.all?(String)
        raise Glazed::Error, "#{path}: requires must be a list of strings"
      end

      requires.each { require it }
      ProtoJson.load(Proto::V1::Config, json).tap { Validation.validate!(it, origin: path) }
    rescue Google::Protobuf::ParseError, JSON::ParserError => e
      hint = e.message.include?('Type was not found') ? '; list the gem providing that plugin type in requires' : ''
      raise Glazed::Error, "#{path}: #{e.message}#{hint}"
    end
  end
end
