# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'dry/cli'
require 'glazed'

module Glazed
  module Command
    # Base of glazed's commands, giving them the output streams dry-cli
    # injects (or the process's own when run directly).
    class Base < Dry::CLI::Command
      # @return [IO] standard output
      #: () -> IO
      private def out = instance_variable_get(:@out) || $stdout

      # @return [IO] standard error
      #: () -> IO
      private def err = instance_variable_get(:@err) || $stderr
    end
  end
end
