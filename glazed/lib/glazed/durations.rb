# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'google/protobuf/well_known_types'

module Glazed
  # Reads google.protobuf.Duration settings.
  module Durations
    # @param duration [Google::Protobuf::Duration, nil] the setting
    # @param default [Numeric] seconds used when the setting is unset or 0
    # @return [Float] seconds
    #: (Google::Protobuf::Duration? duration, Numeric default) -> Float
    def self.seconds(duration, default)
      value = duration&.to_f
      value.nil? || value.zero? ? default.to_f : value
    end
  end
end
