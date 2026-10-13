# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/proto'
require 'glazed/secrets'

module Glazed
  # Secret resolved from a {Proto::V1::SecretRef} on each access. Its value
  # never appears in #inspect or #to_s.
  class Secret
    # Raised when the referenced value cannot be read.
    class Unavailable < Glazed::Error; end

    # @param ref [Proto::V1::SecretRef] reference to resolve
    #: (Proto::V1::SecretRef ref) -> void
    def initialize(ref)
      @ref = ref #: Proto::V1::SecretRef
    end

    # Wraps a reference that may be absent.
    #
    # @param ref [Proto::V1::SecretRef, nil] reference to wrap
    # @return [Secret, nil] the secret, or nil when ref is nil
    #: (Proto::V1::SecretRef? ref) -> Secret?
    def self.maybe(ref)
      ref && new(ref)
    end

    # @return [Proto::V1::SecretRef] the wrapped reference
    #: Proto::V1::SecretRef
    attr_reader :ref

    # Reads the secret value.
    #
    # @return [String] the value
    # @raise [Unavailable] when the environment variable or file is missing, or no source is set
    #: () -> String
    def value
      case ref.source
      when :value then ref.value
      when :env then ENV.fetch(ref.env) { raise Unavailable, "environment variable #{ref.env} is not set" }
      when :file then read_file(ref.file)
      when :plugin then Secrets.build(ref.plugin || raise(Unavailable, 'secret plugin has no settings')).value
      else raise Unavailable, 'secret has no source'
      end
    end

    # @return [String] description naming the source but not the value
    #: () -> String
    def inspect
      case ref.source
      when :env then "#<#{self.class} env:#{ref.env}>"
      when :file then "#<#{self.class} file:#{ref.file}>"
      when :plugin then "#<#{self.class} plugin:#{ref.plugin&.type_name}>"
      else "#<#{self.class} value>"
      end
    end

    alias to_s inspect

    # @param path [String] file to read
    # @return [String] file contents without one trailing newline
    # @raise [Unavailable] when the file cannot be read
    #: (String path) -> String
    private def read_file(path)
      File.read(path).delete_suffix("\n")
    rescue SystemCallError => e
      raise Unavailable, "cannot read secret file #{path}: #{e.message}"
    end
  end
end
