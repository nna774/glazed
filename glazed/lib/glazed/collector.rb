# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/cli_session'
require 'glazed/node_session'
require 'glazed/proto'
require 'glazed/secrets_resolver'
require 'glazed/transports'

module Glazed
  # Collects one node's configuration: connects, logs in, runs the dialect's
  # :get runbook, and logs out.
  #
  # @example
  #   config = Glazed::Collector.new(node:).call
  class Collector
    # @param node [Proto::V1::Node] node to collect from
    # @param transport [Transports::Base, nil] transport to use instead of building one from the node
    # @param timeout [Numeric] seconds to wait for each expected output
    # @param progress [Proc] receives a message when connecting and whenever waiting for the device
    # @param secrets [SecretsResolver] reads the node's password and secrets
    #: (node: Proto::V1::Node, ?transport: Transports::Base?, ?timeout: Numeric, ?progress: ^(String) -> void, ?secrets: SecretsResolver) -> void
    def initialize(node:, transport: nil, timeout: CliSession::DEFAULT_TIMEOUT, progress: ->(_message) {}, secrets: SecretsResolver.new)
      @session = NodeSession.new(node:, transport:, timeout:, progress:, secrets:) #: NodeSession
    end

    # @return [Proto::V1::Node] node to collect from
    #: () -> Proto::V1::Node
    def node = @session.node

    # @return [Class<Dialects::Base>] dialect of the node
    #: () -> singleton(Dialects::Base)
    def dialect = @session.dialect

    # Collects the configuration. The connection is closed even on failure.
    #
    # @return [String] the configuration, in UTF-8
    # @raise [TimeoutError] when the device does not answer as the dialect expects
    # @raise [ConnectionClosed] when the device drops the connection
    # @raise [InvalidEncoding] when the configuration is not valid UTF-8
    #: () -> String
    def call
      @session.open
      begin
        output = dialect.runbook_for(:get).execute(@session.run).dup.force_encoding(Encoding::UTF_8)
        raise InvalidEncoding, "#{node.name}: collected configuration is not valid UTF-8" unless output.valid_encoding?

        @session.logout
        output
      ensure
        @session.close
      end
    end
  end
end
