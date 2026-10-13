# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'

module Glazed
  # ProtoJSON codec that keeps proto field names (snake_case) on output and
  # rejects unknown fields on input.
  module ProtoJson
    # Decodes ProtoJSON into a message.
    #
    # @param klass [Class<Google::Protobuf::AbstractMessage>] message class
    # @param json [String] ProtoJSON document
    # @return [Google::Protobuf::AbstractMessage] decoded message
    # @raise [Google::Protobuf::ParseError] when the document is malformed or has unknown fields
    # @example
    #   Glazed::ProtoJson.load(Glazed::Proto::V1::Node, '{"name": "rt1"}')
    #: [M < Google::Protobuf::AbstractMessage] (singleton(Google::Protobuf::AbstractMessage) & Class[M] klass, String json) -> M
    def self.load(klass, json)
      klass.decode_json(json)
    end

    # Encodes a message into ProtoJSON.
    #
    # @param message [Google::Protobuf::AbstractMessage] message to encode
    # @return [String] ProtoJSON document
    #: (Google::Protobuf::AbstractMessage message) -> String
    def self.dump(message)
      message.class.encode_json(message, preserve_proto_fieldnames: true)
    end
  end
end
