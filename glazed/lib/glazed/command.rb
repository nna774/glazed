# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'dry/cli'
require 'glazed'
require 'glazed/command/orchestrate'
require 'glazed/command/run'
require 'glazed/command/send_signal'
require 'glazed/command/status'
require 'glazed/command/version'

module Glazed
  # Commands of the glazed executable.
  module Command
    extend Dry::CLI::Registry

    register 'orchestrate', Orchestrate
    register 'run', Run
    register 'signal', SendSignal
    register 'status', Status
    register 'version', Version, aliases: ['--version']

    # Runs a command line.
    #
    # @param argv [Array<String>] command line arguments
    # @param out [IO] standard output
    # @param err [IO] standard error, which receives JSON log lines
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
