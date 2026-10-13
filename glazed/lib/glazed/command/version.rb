# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/command/base'
require 'glazed/version'

module Glazed
  module Command
    # `glazed version`: prints the version.
    class Version < Base
      desc 'Print the version'

      # @param _options [Hash] options dry-cli passes, unused
      # @return [void]
      #: (**untyped _options) -> void
      def call(**_options)
        out.puts Glazed::VERSION
      end
    end
  end
end
