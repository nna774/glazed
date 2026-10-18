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
      ProtoJson.load(Proto::V1::Config, json).tap do
        Validation.validate!(it, origin:)
        check_name_regexps(it, origin:)
      end
    rescue Google::Protobuf::ParseError, JSON::ParserError => e
      hint = e.message.include?('Type was not found') ? '; list the gem providing that plugin type in requires' : ''
      raise Glazed::Error, "#{origin}: #{e.message}#{hint}"
    end

    # @param config [Proto::V1::Config] the config
    # @param origin [String] where the config comes from, for error messages
    # @return [void]
    # @raise [InvalidMessage] when a schedule rule's name_regexp does not compile
    #: (Proto::V1::Config config, origin: String) -> void
    private_class_method def self.check_name_regexps(config, origin:)
      config.orchestrator&.workflows&.each do |workflow, orchestration|
        orchestration.schedule_rules.each_with_index do |rule, index|
          Regexp.new(rule.match&.name_regexp.to_s)
        rescue RegexpError => e
          raise InvalidMessage, "#{origin}: orchestrator.workflows.#{workflow}.schedule_rules[#{index}].match.name_regexp: #{e.message}"
        end
      end
    end
  end
end
