# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/cli_session'
require 'glazed/command_result'
require 'glazed/dialect'
require 'glazed/dialect/actions'
require 'glazed/proto'
require 'glazed/secret'
require 'glazed/secrets_resolver'

module Glazed
  module Dialect
    # State of one runbook execution against one node.
    class Run
      # @param cli [CliSession] session to the node
      # @param node [Proto::V1::Node] node being run against
      # @param dialect [Class<Dialects::Base>] dialect of the node
      # @param secrets [SecretsResolver] reads the node's secrets
      #: (cli: CliSession, node: Proto::V1::Node, dialect: singleton(Dialects::Base), ?secrets: SecretsResolver) -> void
      def initialize(cli:, node:, dialect:, secrets: SecretsResolver.new)
        @cli = cli #: CliSession
        @node = node #: Proto::V1::Node
        @dialect = dialect #: singleton(Dialects::Base)
        @secrets = secrets #: SecretsResolver
        @vars = {} #: Hash[Symbol, untyped]
        @output = +'' #: String
      end

      # @return [CliSession] session to the node
      #: CliSession
      attr_reader :cli
      # @return [Proto::V1::Node] node being run against
      #: Proto::V1::Node
      attr_reader :node
      # @return [SecretsResolver] reads the node's secrets
      #: SecretsResolver
      attr_reader :secrets
      # @return [Class<Dialects::Base>] dialect of the node
      #: singleton(Dialects::Base)
      attr_reader :dialect
      # @return [Hash{Symbol => Object}] scratch space shared by the steps of this run
      #: Hash[Symbol, untyped]
      attr_reader :vars
      # @return [String] configuration collected so far
      #: String
      attr_reader :output

      # Runs a command and passes its output, as bytes, through the dialect's
      # output filters. Collected configuration must be UTF-8, so a dialect for
      # a device using another encoding converts it in an output filter.
      #
      # @param line [String] command line
      # @return [CommandResult] the filtered result, in UTF-8
      # @raise [InvalidEncoding] when the filtered output is not valid UTF-8
      #: (String line) -> CommandResult
      def command(line)
        result = cli.command(line)
        filtered = dialect.output_filters.inject(result.output) { |text, output_filter| output_filter.call(text) }
        output = filtered.dup.force_encoding(Encoding::UTF_8)
        unless output.valid_encoding?
          raise InvalidEncoding, "output of #{line.inspect} is not valid UTF-8; convert it in the dialect's filter_output"
        end

        CommandResult.new(command: result.command, output:)
      end

      # Applies an action to the collected configuration.
      #
      # @param action [Actions::Append, Actions::Replace, Actions::Multi, String, nil] action to apply
      # @return [void]
      #: (Actions::action? action) -> void
      def emit(action)
        @output = Actions.apply(@output, action)
      end

      # @param name [String] parameter name
      # @return [String, nil] the node's parameter value
      #: (String name) -> String?
      def param(name) = node.params[name]

      # @param name [String] secret name
      # @return [Secret, nil] the node's secret
      #: (String name) -> Secret?
      def secret(name) = secrets.maybe(node.secrets[name])
    end
  end
end
