# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'

module Glazed
  # Output of one command run on a device.
  class CommandResult
    # @param command [String] command line that was run
    # @param output [String] output without the echoed command or trailing prompt
    #: (command: String, output: String) -> void
    def initialize(command:, output:)
      @command = command #: String
      @output = output #: String
    end

    # @return [String] command line that was run
    #: String
    attr_reader :command
    # @return [String] output without the echoed command or trailing prompt
    #: String
    attr_reader :output
  end
end
