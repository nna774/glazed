# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

module Glazed
  # Resolves plugin classes by name, requiring `<prefix>/<name>` on demand so
  # other gems can provide implementations.
  module Finder
    # Raised when no implementation is found for a name.
    class NotFound < Glazed::Error; end

    # Looks up the constant for a snake_case name under a namespace.
    #
    # @param namespace [Module] namespace holding implementations
    # @param prefix [String] require path prefix for the namespace
    # @param name [String, Symbol] snake_case implementation name
    # @return [Module] the implementation
    # @raise [NotFound] when the constant cannot be found even after requiring
    # @example
    #   Glazed::Finder.find(Glazed::Storages, 'glazed/storages', 's3')
    #: (Module[untyped] namespace, String prefix, String | Symbol name) -> Module[untyped]
    def self.find(namespace, prefix, name)
      maybe_find(namespace, prefix, name) or raise NotFound, "Couldn't find #{name.inspect} for #{namespace}"
    end

    # Looks up the constant for a snake_case name, returning nil when absent.
    #
    # @param namespace [Module] namespace holding implementations
    # @param prefix [String] require path prefix for the namespace
    # @param name [String, Symbol] snake_case implementation name
    # @return [Module, nil] the implementation
    #: (Module[untyped] namespace, String prefix, String | Symbol name) -> Module[untyped]?
    def self.maybe_find(namespace, prefix, name)
      constant_name = name.to_s.split('_').map(&:capitalize).join
      return lookup(namespace, constant_name) if namespace.const_defined?(constant_name, false)

      begin
        require "#{prefix}/#{name}"
      rescue LoadError
        return nil
      end
      lookup(namespace, constant_name) if namespace.const_defined?(constant_name, false)
    end

    # @param namespace [Module] namespace holding implementations
    # @param constant_name [String] constant to read
    # @return [Module] the constant, which must be a module or class
    # @raise [NotFound] when the constant is not a module
    #: (Module[untyped] namespace, String constant_name) -> Module[untyped]
    private_class_method def self.lookup(namespace, constant_name)
      value = namespace.const_get(constant_name, false)
      raise NotFound, "#{namespace}::#{constant_name} is not a module" unless value.is_a?(Module)

      value
    end
  end
end
