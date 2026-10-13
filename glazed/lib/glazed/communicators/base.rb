# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

module Glazed
  module Communicators
    class Base
      def initialize
        @prompt = /^([\w.@-]+[#>]\s?)$/
        @interactions = []
        @data_filters = []
      end

      attr_accessor :prompt
      attr_accessor :interactions
      attr_accessor :data_filters

      def configure(&block)
        raise NotImplementedError
      end
    end
  end
end
