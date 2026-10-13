# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialect'
require 'glazed/dialect/actions'

module Glazed
  module Dialect
    #: type responder = ^(CliSession session, String buffer, MatchData match) -> Actions::action?
    #: type data_filter = ^(String fragment) -> String

    # Responds to a pattern appearing in the session buffer, such as a pager prompt.
    class Interaction
      # @param pattern [Regexp] pattern matched against the session buffer
      # @param responder [Proc] called with the session, a copy of the buffer and the match; returns an action applied to the buffer
      #: (pattern: Regexp, responder: Dialect::responder) -> void
      def initialize(pattern:, responder:)
        @pattern = pattern #: Regexp
        @responder = responder #: Dialect::responder
      end

      # @return [Regexp] pattern matched against the session buffer
      #: Regexp
      attr_reader :pattern
      # @return [Proc] responder returning an action applied to the buffer
      #: Dialect::responder
      attr_reader :responder
    end
  end
end
