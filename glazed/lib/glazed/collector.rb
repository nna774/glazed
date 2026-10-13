# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/cli_session'
require 'glazed/dialect/run'
require 'glazed/dialects'
require 'glazed/proto'
require 'glazed/secret'
require 'glazed/transports'

module Glazed
  # Collects one node's configuration: connects, logs in, runs the dialect's
  # :get runbook, and logs out.
  #
  # @example
  #   config = Glazed::Collector.new(node:).call
  class Collector
    # Transport used when a node names none.
    DEFAULT_TRANSPORT = 'ssh' #: String

    # @param node [Proto::V1::Node] node to collect from
    # @param transport [Transports::Base, nil] transport to use instead of building one from the node
    # @param timeout [Numeric] seconds to wait for each expected output
    #: (node: Proto::V1::Node, ?transport: Transports::Base?, ?timeout: Numeric) -> void
    def initialize(node:, transport: nil, timeout: CliSession::DEFAULT_TIMEOUT)
      @node = node #: Proto::V1::Node
      @dialect = Dialects.find(node.dialect) #: singleton(Dialects::Base)
      @kind = (node.transport.empty? ? DEFAULT_TRANSPORT : node.transport) #: String
      @transport = transport || build_transport #: Transports::Base
      @config = @dialect.communication_config(@kind.to_sym) #: Dialect::CommunicationConfig
      @timeout = timeout #: Numeric
    end

    # @return [Proto::V1::Node] node to collect from
    #: Proto::V1::Node
    attr_reader :node
    # @return [Class<Dialects::Base>] dialect of the node
    #: singleton(Dialects::Base)
    attr_reader :dialect

    # Collects the configuration. The connection is closed even on failure.
    #
    # @return [String] the configuration, in UTF-8
    # @raise [TimeoutError] when the device does not answer as the dialect expects
    # @raise [ConnectionClosed] when the device drops the connection
    # @raise [InvalidEncoding] when the configuration is not valid UTF-8
    #: () -> String
    def call
      session = CliSession.new(
        transport: @transport,
        prompt: dialect.prompt_pattern,
        data_filters: dialect.data_filters,
        interactions: dialect.interactions,
        exec: @config.exec,
        timeout: @timeout,
      )
      run = Dialect::Run.new(cli: session, node:, dialect:)
      @transport.pty_options = @config.pty_options
      @transport.open
      begin
        login(session) unless exec_only?
        @config.post_login_hooks.each { it.call(run) }
        output = dialect.runbook_for(:get).execute(run).dup.force_encoding(Encoding::UTF_8)
        raise InvalidEncoding, "#{node.name}: collected configuration is not valid UTF-8" unless output.valid_encoding?

        @config.pre_logout_hooks.each { it.call(run) }
        output
      ensure
        @transport.close
      end
    end

    # @return [Boolean] whether every command runs on exec channels, so the shell is never used
    #: () -> bool
    private def exec_only? = @config.exec && @transport.exec?

    # Answers login prompts the dialect declares, then waits for the first prompt.
    #
    # @param session [CliSession] session to log in through
    # @return [void]
    #: (CliSession session) -> void
    private def login(session)
      if (username_prompt = @config.username_prompt)
        session.expect(username_prompt)
        session.write("#{node.username}\n")
      end
      if (password_prompt = @config.password_prompt)
        session.expect(password_prompt)
        session.write("#{Secret.maybe(node.password)&.value}\n")
      end
      session.expect(session.prompt)
    end

    # @return [Transports::Base] transport built from the node
    # @raise [Finder::NotFound] when the transport is unknown
    #: () -> Transports::Base
    private def build_transport
      Transports.find(@kind).new(
        host: node.host.empty? ? node.name : node.host,
        port: node.port.zero? ? nil : node.port,
        username: node.username,
        password: Secret.maybe(node.password),
      )
    end
  end
end
