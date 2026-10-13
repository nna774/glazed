# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'google/protobuf'
require 'glazed'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/secret'
require 'glazed/secrets'

module Glazed
  # Reads the values of {Proto::V1::SecretRef}s. Sources other than a value,
  # an environment variable or a file are built once per reference and kept
  # here, so a source that caches what it fetches, such as glazed-aws's
  # `ssm`, does so for as long as this resolver lives.
  #
  # @example
  #   secrets = Glazed::SecretsResolver.new
  #   secrets.secret(node.password).value
  class SecretsResolver
    #: () -> void
    def initialize
      @sources = {} #: Hash[String, Secrets::Base]
      @lock = Mutex.new #: Thread::Mutex
    end

    # @param ref [Proto::V1::SecretRef] reference to wrap
    # @return [Secret] the secret, read through this resolver
    #: (Proto::V1::SecretRef ref) -> Secret
    def secret(ref) = Secret.new(ref, resolver: self)

    # @param ref [Proto::V1::SecretRef, nil] reference to wrap
    # @return [Secret, nil] the secret, or nil when ref is nil
    #: (Proto::V1::SecretRef? ref) -> Secret?
    def maybe(ref) = ref && secret(ref)

    # Reads a secret value.
    #
    # @param ref [Proto::V1::SecretRef] reference to read
    # @return [String] the value
    # @raise [Secret::Unavailable] when the value cannot be read, or no source is set
    # @raise [Finder::NotFound] when the source is provided by a gem that is not installed
    # @raise [PluginRegistry::UnknownPlugin] when no plugin is registered for the settings type
    #: (Proto::V1::SecretRef ref) -> String
    def value(ref)
      case ref.source
      when :value then ref.value
      when :env then ENV.fetch(ref.env) { raise Secret::Unavailable, "environment variable #{ref.env} is not set" }
      when :file then read_file(ref.file)
      when nil then raise Secret::Unavailable, 'secret has no source'
      else source(ref).value
      end
    end

    # @param ref [Proto::V1::SecretRef] reference with a plugin or gem-provided source
    # @return [Secrets::Base] the source, built on first use
    #: (Proto::V1::SecretRef ref) -> Secrets::Base
    private def source(ref)
      key = Proto::V1::SecretRef.encode(ref)
      @lock.synchronize { @sources[key] ||= build(ref) }
    end

    # @param ref [Proto::V1::SecretRef] reference with a plugin or gem-provided source
    # @return [Secrets::Base] the source
    #: (Proto::V1::SecretRef ref) -> Secrets::Base
    private def build(ref)
      kind = Must.because(ref.source) { 'value reads only references with a source' }
      return Secrets.build(Must.because(ref.plugin) { 'plugin is the selected source' }) if kind == :plugin

      Secrets.find(kind).from_proto(Must.be_a(ref[kind.to_s], Google::Protobuf::MessageExts))
    end

    # @param path [String] file to read
    # @return [String] file contents without one trailing newline
    # @raise [Secret::Unavailable] when the file cannot be read
    #: (String path) -> String
    private def read_file(path)
      File.read(path).delete_suffix("\n")
    rescue SystemCallError => e
      raise Secret::Unavailable, "cannot read secret file #{path}: #{e.message}"
    end
  end
end
