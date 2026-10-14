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
  # Only the secret within each match is replaced, by +[~REDACTED~]+ in :remove
  # mode or +[~REDACTED:dgst=...~]+ in :hmac mode. The digest is a truncated
  # HMAC-SHA256 of the secret in unpadded base64url, so a changed secret shows
  # up in diffs without being revealed. A pattern with a note adds +:note=...+
  # before the closing +~]+.
  #
  # @example
  #   Glazed::Redactor.new(patterns: Glazed::Dialects::Ios.sensitive_patterns, mode: :remove).call(config)
  class Redactor
    # Raised when the redaction settings are unusable.
    class InvalidConfiguration < Glazed::Error; end

    # Replacement in :remove mode.
    REMOVED = '[~REDACTED~]' #: String
    # Bytes of the HMAC kept in :hmac mode.
    HMAC_BYTES = 8 #: Integer

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
    # Secrets of +redaction+ and +global+ both apply. +redaction+ takes precedence
    # for the mode and the HMAC key when it sets them.
    #
    # @param redaction [Proto::V1::Redaction] redaction settings
    # @param patterns [Array<Dialect::SensitivePattern>] where secrets appear
    # @param global [Proto::V1::Redaction, nil] settings shared by every redactor
    # @return [Redactor] the redactor
    # @raise [InvalidConfiguration] when the mode is unknown, the HMAC key is missing or not base64, or a regexp is invalid
    # @raise [Secret::Unavailable] when the HMAC key or a secret cannot be read
    #: (Proto::V1::Redaction redaction, patterns: Array[Dialect::SensitivePattern], ?global: Proto::V1::Redaction?) -> Redactor
    def self.from_proto(redaction, patterns:, global: nil)
      patterns += ((global&.secrets&.to_a || []) + redaction.secrets.to_a).filter_map { extra_pattern(it) }
      mode = redaction.mode == :MODE_UNSPECIFIED && global ? global.mode : redaction.mode
      case mode
      when :MODE_UNSPECIFIED, :MODE_REMOVE then new(patterns:, mode: :remove)
      when :MODE_HMAC then new(patterns:, mode: :hmac, key: hmac_key(redaction.hmac_key || global&.hmac_key))
      else raise InvalidConfiguration, "unknown redaction mode #{mode.inspect}"
      end
    end

    # @param extra [Proto::V1::ExtraSecret] secret to hide
    # @return [Dialect::SensitivePattern, nil] pattern locating it, or nil when it has no value
    # @raise [InvalidConfiguration] when a regexp is invalid
    # @raise [Secret::Unavailable] when the referenced value cannot be read
    #: (Proto::V1::ExtraSecret extra) -> Dialect::SensitivePattern?
    private_class_method def self.extra_pattern(extra)
      whole_match = ->(match) { match.begin(0)...match.end(0) } #: Dialect::SensitivePattern::determiner
      note = extra.note.empty? ? nil : extra.note
      ref = extra.ref or raise InvalidConfiguration, 'redaction secret has no ref'
      value = Secret.new(ref).value
      values = (extra.delimiter.empty? ? [value] : value.split(extra.delimiter)).reject(&:empty?)
      return nil if values.empty?

      pattern = if extra.regexp
        Regexp.union(values.map { Regexp.new(it) })
      else
        Regexp.union(values.sort_by { -it.size })
      end
      Dialect::SensitivePattern.new(pattern:, determiner: whole_match, note:)
    rescue RegexpError => e
      raise InvalidConfiguration, "invalid regexp in redaction secrets: #{e.message}"
    end

    # @param ref [Proto::V1::SecretRef, nil] reference to the base64 key
    # @return [String, nil] the HMAC key, decoded from base64
    # @raise [InvalidConfiguration] when the key is not base64
    # @raise [Secret::Unavailable] when the key cannot be read
    #: (Proto::V1::SecretRef? ref) -> String?
    private_class_method def self.hmac_key(ref)
      encoded = Secret.maybe(ref)&.value or return nil
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
      secret_ranges(text).reverse_each do |start, finish, note|
        result[start...finish] = replacement(text[start...finish] || '', note)
      end
      result
    end

    # @param text [String] configuration text
    # @return [Array<Array(Integer, Integer, String?)>] non-overlapping secret start and end offsets, each with the
    #   note of the pattern that located it, in order
    #: (String text) -> Array[[Integer, Integer, String?]]
    private def secret_ranges(text)
      ranges = @patterns.flat_map do |sensitive|
        matches(sensitive.pattern, text).filter_map do |match|
          range = case (secret = sensitive.determiner.call(match))
          when Range
            start = secret.begin
            finish = secret.exclude_end? ? secret.end : secret.end + 1
            [start, finish] if finish > start
          when String then locate(match, secret) unless secret.empty?
          end
          [range[0], range[1], sensitive.note] if range
        end
      end
      kept = [] #: Array[[Integer, Integer, String?]]
      ranges.sort_by { |start, finish,| [start, -finish] }.each do |range|
        last = kept.last
        kept << range if last.nil? || range[0] >= last[1]
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
    # @param note [String, nil] note of the pattern that located the secret
    # @return [String] its replacement
    #: (String secret, String? note) -> String
    private def replacement(secret, note)
      fields = [] #: Array[String]
      if @mode == :hmac
        digest = OpenSSL::HMAC.digest('SHA256', @key.to_s, secret).byteslice(0, HMAC_BYTES)
        fields << "dgst=#{[digest].pack('m0').tr('+/', '-_').delete('=')}"
      end
      fields << "note=#{note}" if note
      fields.empty? ? REMOVED : "[~REDACTED:#{fields.join(':')}~]"
    end
  end
end
