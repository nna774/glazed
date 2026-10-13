# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/finder'
require 'glazed/must'
require 'glazed/transports/base'

module Glazed
  # Namespace of transport implementations, looked up by name.
  module Transports
    # Finds a transport class by snake_case name.
    #
    # @param name [String, Symbol] transport name, such as "ssh"
    # @return [Class<Base>] the transport class
    # @raise [Finder::NotFound] when there is none
    # @raise [Must::Violation] when the name resolves to something other than a transport
    #: (String | Symbol name) -> singleton(Base)
    def self.find(name)
      found = Finder.find(self, 'glazed/transports', name)
      return found if found.is_a?(Class) && found < Base

      raise Must::Violation, "#{found} is not a transport"
    end
  end
end
