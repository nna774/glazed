# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/finder'

module Glazed
  # Namespace of storage implementations, looked up by name.
  module Storages
    # Finds an implementation by snake_case name.
    #
    # @param name [String, Symbol] implementation name
    # @return [Module] the implementation
    # @raise [Finder::NotFound] when there is none
    #: (String | Symbol name) -> Module[untyped]
    def self.find(name)
      Finder.find(self, 'glazed/storages', name)
    end
  end
end
