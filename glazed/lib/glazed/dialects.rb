# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/finder'

module Glazed
  module Dialects
    def self.find(name)
      Finder.find(self, 'glazed/dialects', name)
    end
  end
end
