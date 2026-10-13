# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'optparse'
require 'glazed'
require 'glazed/version'

module Glazed
  # Entry point of the glazed executable.
  module Command
    # Usage shown for unknown or missing subcommands.
    USAGE = <<~TEXT #: String
      Usage: glazed <command> [options]

      Commands:
        run      Collect configuration from every node, store it raw and publish it redacted
        version  Print the version
    TEXT

    # Runs a subcommand.
    #
    # @param argv [Array<String>] command line arguments
    # @param out [IO] standard output
    # @param err [IO] standard error, which receives JSON log lines
    # @return [Integer] exit status
    #: (Array[String] argv, ?out: IO, ?err: IO) -> Integer
    def self.start(argv, out: $stdout, err: $stderr)
      command, *args = argv
      case command
      when 'run'
        require 'glazed/command/run'
        Run.parse(args).call(out:, err:)
      when 'version'
        out.puts Glazed::VERSION
        0
      else
        err.puts USAGE
        2
      end
    rescue OptionParser::ParseError => e
      err.puts e.message
      2
    end
  end
end
