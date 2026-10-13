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
      #: (pattern: Regexp, determiner: SensitivePattern::determiner) -> void
      def initialize(pattern:, determiner:)
        @pattern = pattern #: Regexp
        @determiner = determiner #: SensitivePattern::determiner
      end

      # @return [Regexp] pattern matched against the whole configuration
      #: Regexp
      attr_reader :pattern
      # @return [Proc] returns the secret within a match, or its offsets
      #: SensitivePattern::determiner
      attr_reader :determiner
    end
  end
end
