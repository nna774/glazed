# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/finder'

module Glazed
  module Communicators
    def self.find(name)
      Finder.find(self, 'glazed/communicators', name)
    end
  end
end
