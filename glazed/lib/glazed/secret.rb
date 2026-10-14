# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/proto'

module Glazed
  # Secret read from a {Proto::V1::SecretRef} through a {SecretsResolver} on
  # each access. Its value never appears in #inspect or #to_s.
  class Secret
    # Raised when the referenced value cannot be read.
    class Unavailable < Glazed::Error; end

    # @param ref [Proto::V1::SecretRef] reference to read
    # @param resolver [SecretsResolver] reads the value
    #: (Proto::V1::SecretRef ref, resolver: SecretsResolver) -> void
    def initialize(ref, resolver:)
      @ref = ref #: Proto::V1::SecretRef
      @resolver = resolver #: SecretsResolver
    end

    # @return [Proto::V1::SecretRef] the wrapped reference
    #: Proto::V1::SecretRef
    attr_reader :ref

    # Reads the secret value.
    #
    # @return [String] the value
    # @raise [Unavailable] when the value cannot be read, or no source is set
    #: () -> String
    def value = @resolver.value(ref)

    # @return [String] description naming the source but not the value
    #: () -> String
    def inspect
      case (source = ref.source)
      when :value, nil then "#<#{self.class} value>"
      when :env then "#<#{self.class} env:#{ref.env}>"
      when :file then "#<#{self.class} file:#{ref.file}>"
      when :plugin then "#<#{self.class} plugin:#{ref.plugin&.type_name}>"
      else "#<#{self.class} #{source}>"
      end
    end

    alias to_s inspect
  end
end
