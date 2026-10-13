# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/finder'
require 'glazed/must'
require 'glazed/dialects/base'

module Glazed
  # Namespace of dialects, looked up by name.
  module Dialects
    #: type resolver = ^(String name) -> singleton(Base)?

    @resolvers = [] #: Array[Dialects::resolver]
    @resolvers_lock = Mutex.new #: Thread::Mutex

    # Finds a dialect class by snake_case name, then asks each resolver in
    # registration order.
    #
    # @param name [String, Symbol] dialect name, such as "ios"
    # @return [Class<Base>] the dialect class
    # @raise [Finder::NotFound] when there is none
    # @raise [Must::Violation] when the name resolves to something other than a dialect
    #: (String | Symbol name) -> singleton(Base)
    def self.find(name)
      found = Finder.maybe_find(self, 'glazed/dialects', name) || resolve(name.to_s)
      raise Finder::NotFound, "Couldn't find #{name.inspect} for #{self}" unless found
      return found if found.is_a?(Class) && found < Base

      raise Must::Violation, "#{found} is not a dialect"
    end

    # Registers a resolver for names that no dialect class or file answers to,
    # such as dialects generated from another format.
    #
    # @yieldparam name [String] dialect name
    # @yieldreturn [Class<Base>, nil] the dialect, or nil when the resolver has none by that name
    # @return [void]
    # @example
    #   Glazed::Dialects.add_resolver { |name| GENERATED[name] }
    #: () { (String name) -> singleton(Base)? } -> void
    def self.add_resolver(&resolver)
      @resolvers_lock.synchronize { @resolvers << resolver }
    end

    # Removes a resolver registered with {add_resolver}.
    #
    # @param resolver [Proc] the resolver
    # @return [void]
    #: (Dialects::resolver resolver) -> void
    def self.remove_resolver(resolver)
      @resolvers_lock.synchronize { @resolvers.delete(resolver) }
    end

    # @param name [String] dialect name
    # @return [Class<Base>, nil] the first dialect a resolver returns
    #: (String name) -> singleton(Base)?
    private_class_method def self.resolve(name)
      resolvers = @resolvers_lock.synchronize { @resolvers.dup }
      resolvers.lazy.filter_map { it.call(name) }.first
    end
  end
end
