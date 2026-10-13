# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/must'

module Glazed
  module Oxidized
    # A substitution from a model's `cmd :secret` block, which hides secrets
    # by replacing matches of a pattern. The secret is what the replacement
    # drops from a match.
    #
    # @example
    #   substitution = Glazed::Oxidized::SecretSubstitution.new(pattern: /^(snmp-server community) \S+/, replacement: '\\1 <hidden>')
    #   match = substitution.pattern.match('snmp-server community public')
    #   substitution.offsets(match) #=> 22...28
    class SecretSubstitution
      # Backreferences in a replacement, as String#sub expands them.
      BACKREFERENCE = /\\(?:(\d)|k<(\w+)>|([&`'+\\]))/ #: Regexp

      # @param pattern [Regexp] pattern the block substitutes
      # @param replacement [String] replacement, with backreferences
      #: (pattern: Regexp, replacement: String) -> void
      def initialize(pattern:, replacement:)
        @pattern = pattern #: Regexp
        @replacement = replacement #: String
      end

      # @return [Regexp] pattern the block substitutes
      #: Regexp
      attr_reader :pattern
      # @return [String] replacement, with backreferences
      #: String
      attr_reader :replacement

      # Finds the text the replacement drops from a match: the match without
      # the start and end it shares with its replacement, and without
      # surrounding whitespace. A shared start or end never ends inside a word,
      # so a secret beginning like the replacement is not partly kept.
      #
      # @param match [MatchData] a match of {pattern}
      # @return [Range<Integer>, nil] offsets of the dropped text in the matched string, or nil when nothing is dropped
      #: (MatchData match) -> Range[Integer]?
      def offsets(match)
        matched = match[0].to_s
        replaced = expand(match)
        head = shared_length(matched, replaced)
        head -= 1 while head.positive? && word?(matched[head - 1]) && word?(matched[head])
        tail = shared_length(matched[head..].to_s.reverse, replaced[head..].to_s.reverse)
        tail -= 1 while tail.positive? && word?(matched[-tail - 1]) && word?(matched[-tail])
        start = head
        finish = matched.size - tail
        start += 1 while start < finish && whitespace?(matched[start])
        finish -= 1 while finish > start && whitespace?(matched[finish - 1])
        return nil if start >= finish

        origin = match.begin(0)
        (origin + start)...(origin + finish)
      end

      # @param match [MatchData] a match of {pattern}
      # @return [String] the replacement with its backreferences expanded
      #: (MatchData match) -> String
      private def expand(match)
        replacement.gsub(BACKREFERENCE) do
          reference = Must.expect(Regexp.last_match)
          if (group = reference[1])
            match[group.to_i].to_s
          elsif (name = reference[2])
            match[name].to_s
          else
            case reference[3]
            when '&' then match[0].to_s
            when '`' then match.pre_match
            when "'" then match.post_match
            when '+' then match.captures.compact.last.to_s
            else '\\'
            end
          end
        end
      end

      # @param left [String] a string
      # @param right [String] another string
      # @return [Integer] length of the start the strings share
      #: (String left, String right) -> Integer
      private def shared_length(left, right)
        length = 0
        length += 1 while length < left.size && length < right.size && left[length] == right[length]
        length
      end

      # @param char [String, nil] a character
      # @return [Boolean] whether it is a word character
      #: (String? char) -> bool
      private def word?(char) = char&.match?(/\w/) || false

      # @param char [String, nil] a character
      # @return [Boolean] whether it is whitespace
      #: (String? char) -> bool
      private def whitespace?(char) = char&.match?(/\s/) || false
    end
  end
end
