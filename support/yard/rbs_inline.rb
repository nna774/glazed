# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'yard'

module Glazed
  module YardSupport
    # Docstring parser that drops inline RBS annotation lines (`#:` and `#|`).
    class RbsInlineDocstringParser < YARD::DocstringParser
      # @param content [String] raw comment text without leading `#`
      # @param object [YARD::CodeObjects::Base, nil] object being documented
      # @param handler [YARD::Handlers::Base, nil] handler parsing the object
      # @return [self]
      def parse(content, object = nil, handler = nil)
        content = content.each_line.grep_v(/\A\s*[:|]/).join if content.is_a?(String)
        super
      end
    end
  end
end

YARD::Docstring.default_parser = Glazed::YardSupport::RbsInlineDocstringParser
