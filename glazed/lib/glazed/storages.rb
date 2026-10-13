# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/finder'

module Glazed
  module Storages
    def self.find(name)
      Finder.find(self, 'glazed/storages', name)
    end
  end
end
