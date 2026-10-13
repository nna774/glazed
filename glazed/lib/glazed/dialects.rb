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
    # Finds a dialect class by snake_case name.
    #
    # @param name [String, Symbol] dialect name, such as "ios"
    # @return [Class<Base>] the dialect class
    # @raise [Finder::NotFound] when there is none
    # @raise [Must::Violation] when the name resolves to something other than a dialect
    #: (String | Symbol name) -> singleton(Base)
    def self.find(name)
      found = Finder.find(self, 'glazed/dialects', name)
      return found if found.is_a?(Class) && found < Base

      raise Must::Violation, "#{found} is not a dialect"
    end
  end
end
