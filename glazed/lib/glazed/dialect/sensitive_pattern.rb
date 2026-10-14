# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialect'

module Glazed
  module Dialect
    # Locates secrets in configuration text.
    class SensitivePattern
      #: type determiner = ^(MatchData match) -> (String | Range[Integer])?

      # @param pattern [Regexp] pattern matched against the whole configuration
      # @param determiner [Proc] returns the secret within a match, or its offsets in the configuration,
      #   or nil when the match holds none
      # @param note [String, nil] shown in the replacement of every secret this pattern locates
      #: (pattern: Regexp, determiner: SensitivePattern::determiner, ?note: String?) -> void
      def initialize(pattern:, determiner:, note: nil)
        @pattern = pattern #: Regexp
        @determiner = determiner #: SensitivePattern::determiner
        @note = note #: String?
      end

      # @return [Regexp] pattern matched against the whole configuration
      #: Regexp
      attr_reader :pattern
      # @return [Proc] returns the secret within a match, or its offsets
      #: SensitivePattern::determiner
      attr_reader :determiner
      # @return [String, nil] shown in the replacement of every secret this pattern locates
      #: String?
      attr_reader :note
    end
  end
end
