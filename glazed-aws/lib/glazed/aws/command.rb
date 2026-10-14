# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'dry/cli'
require 'glazed/aws'
require 'glazed/aws/command/state_machine'

module Glazed
  module Aws
    # Commands of the glazed-aws executable.
    module Command
      extend Dry::CLI::Registry

      register 'state-machine', StateMachine

      # Runs a command line.
      #
      # @param argv [Array<String>] command line arguments
      # @param out [IO] standard output
      # @param err [IO] standard error
      # @return [Integer] exit status
      #: (Array[String] argv, ?out: IO, ?err: IO) -> Integer
      def self.start(argv, out: $stdout, err: $stderr)
        Dry::CLI.new(self).call(arguments: argv, out:, err:)
        0
      rescue SystemExit => e
        e.status
      end
    end
  end
end
