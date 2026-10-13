# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'openssl'
require 'glazed'
require 'glazed/dialect/sensitive_pattern'
require 'glazed/proto'
require 'glazed/secret'

module Glazed
  # Hides secrets located by a dialect's sensitive patterns.
  #
  # Only the secret within each match is replaced. In :hmac mode the
  # replacement is a truncated HMAC-SHA256 of the secret, so a changed secret
  # shows up in diffs without being revealed.
  #
  # @example
  #   Glazed::Redactor.new(patterns: Glazed::Dialects::Ios.sensitive_patterns, mode: :remove).call(config)
  class Redactor
    # Raised when the redaction settings are unusable.
    class InvalidConfiguration < Glazed::Error; end

    # Replacement in :remove mode.
    REMOVED = '<secret removed>' #: String
    # Hex digits of the HMAC kept in :hmac mode.
    HMAC_LENGTH = 16 #: Integer

    # Supported modes.
    MODES = %i[remove hmac].freeze #: Array[Symbol]

    # @param patterns [Array<Dialect::SensitivePattern>] where secrets appear
    # @param mode [Symbol] :remove or :hmac
    # @param key [String, nil] HMAC key, required for :hmac
    # @raise [InvalidConfiguration] when the mode is unknown or :hmac has no key
    #: (patterns: Array[Dialect::SensitivePattern], mode: Symbol, ?key: String?) -> void
    def initialize(patterns:, mode:, key: nil)
      raise InvalidConfiguration, "unknown redaction mode #{mode.inspect}" unless MODES.include?(mode)
      raise InvalidConfiguration, 'HMAC redaction requires a key' if mode == :hmac && (key.nil? || key.empty?)

      @patterns = patterns #: Array[Dialect::SensitivePattern]
      @mode = mode #: Symbol
      @key = key #: String?
    end

    # Builds a redactor from settings.
    #
    # @param redaction [Proto::V1::Redaction] redaction settings
    # @param patterns [Array<Dialect::SensitivePattern>] where secrets appear
    # @return [Redactor] the redactor
    # @raise [InvalidConfiguration] when the mode is unknown, or the HMAC key is missing or not base64
    # @raise [Secret::Unavailable] when the HMAC key cannot be read
    #: (Proto::V1::Redaction redaction, patterns: Array[Dialect::SensitivePattern]) -> Redactor
    def self.from_proto(redaction, patterns:)
      case redaction.mode
      when :MODE_UNSPECIFIED, :MODE_REMOVE then new(patterns:, mode: :remove)
      when :MODE_HMAC then new(patterns:, mode: :hmac, key: hmac_key(redaction))
      else raise InvalidConfiguration, "unknown redaction mode #{redaction.mode.inspect}"
      end
    end

    # @param redaction [Proto::V1::Redaction] redaction settings
    # @return [String, nil] the HMAC key, decoded from base64
    # @raise [InvalidConfiguration] when the key is not base64
    # @raise [Secret::Unavailable] when the key cannot be read
    #: (Proto::V1::Redaction redaction) -> String?
    private_class_method def self.hmac_key(redaction)
      encoded = Secret.maybe(redaction.hmac_key)&.value or return nil
      encoded.unpack1('m0')
    rescue ArgumentError
      raise InvalidConfiguration, 'hmac_key is not base64'
    end

    # @return [Symbol] :remove or :hmac
    #: Symbol
    attr_reader :mode

    # Redacts a configuration.
    #
    # @param text [String] configuration text
    # @return [String] text with every located secret replaced
    #: (String text) -> String
    def call(text)
      result = text.dup
      secret_ranges(text).reverse_each do |start, finish|
        result[start...finish] = replacement(text[start...finish] || '')
      end
      result
    end

    # @param text [String] configuration text
    # @return [Array<Array(Integer, Integer)>] non-overlapping secret start and end offsets, in order
    #: (String text) -> Array[[Integer, Integer]]
    private def secret_ranges(text)
      ranges = @patterns.flat_map do |sensitive|
        matches(sensitive.pattern, text).filter_map do |match|
          secret = sensitive.determiner.call(match)
          locate(match, secret) if secret && !secret.empty?
        end
      end
      kept = [] #: Array[[Integer, Integer]]
      ranges.sort_by { |start, finish| [start, -finish] }.each do |start, finish|
        last = kept.last
        kept << [start, finish] if last.nil? || start >= last[1]
      end
      kept
    end

    # @param pattern [Regexp] pattern to scan for
    # @param text [String] text to scan
    # @return [Array<MatchData>] every match
    #: (Regexp pattern, String text) -> Array[MatchData]
    private def matches(pattern, text)
      found = [] #: Array[MatchData]
      position = 0
      while (match = pattern.match(text, position))
        found << match
        position = match.end(0) > match.begin(0) ? match.end(0) : match.end(0) + 1
        break if position > text.size
      end
      found
    end

    # Finds the secret in a match, preferring the last capture group equal to it,
    # as secrets follow the names they belong to.
    #
    # @param match [MatchData] the match
    # @param secret [String] secret returned by the determiner
    # @return [Array(Integer, Integer), nil] start and end offsets of the secret, or nil when it is not in the match
    #: (MatchData match, String secret) -> [Integer, Integer]?
    private def locate(match, secret)
      group = (match.size - 1).downto(1).find { match[it] == secret }
      start = if group
        match.begin(group)
      elsif (offset = match[0]&.rindex(secret))
        match.begin(0) + offset
              end
      [start, start + secret.size] if start
    end

    # @param secret [String] secret to hide
    # @return [String] its replacement
    #: (String secret) -> String
    private def replacement(secret)
      return REMOVED unless @mode == :hmac

      "<secret hmac:#{OpenSSL::HMAC.hexdigest('SHA256', @key.to_s, secret)[0, HMAC_LENGTH]}>"
    end
  end
end
