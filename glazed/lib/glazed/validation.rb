# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'protovalidate'
require 'glazed'

module Glazed
  # Raised when a message breaks the buf.validate rules of its schema.
  class InvalidMessage < Error; end

  # Checks messages against the buf.validate rules declared in their schema,
  # including rules plugin gems declare for their settings.
  module Validation
    # @param message [Google::Protobuf::MessageExts] message to check
    # @param origin [String, nil] where the message comes from, for the error message
    # @return [void]
    # @raise [InvalidMessage] listing every violation
    # @example
    #   Glazed::Validation.validate!(config, origin: 'glazed.json')
    #: (Google::Protobuf::MessageExts message, ?origin: String?) -> void
    def self.validate!(message, origin: nil)
      Protovalidate.validate(message)
    rescue Protovalidate::ValidationError => e
      details = e.violations.join('; ')
      raise InvalidMessage, origin ? "#{origin}: #{details}" : details
    end
  end
end
