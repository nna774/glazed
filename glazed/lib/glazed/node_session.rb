# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed'
require 'glazed/cli_session'
require 'glazed/dialect/run'
require 'glazed/dialects'
require 'glazed/proto'
require 'glazed/secrets_resolver'
require 'glazed/transports'

module Glazed
  # Logged-in session to one node: connects, answers the dialect's login
  # prompts, runs its post-login hooks, and later its pre-logout hooks.
  #
  # @example
  #   session = Glazed::NodeSession.new(node:)
  #   session.open
  #   begin
  #     session.run.command('show version')
  #     session.logout
  #   ensure
  #     session.close
  #   end
  class NodeSession
    # Transport used when a node names none.
    DEFAULT_TRANSPORT = 'ssh' #: String

    # @param node [Proto::V1::Node] node to connect to
    # @param transport [Transports::Base, nil] transport to use instead of building one from the node
    # @param timeout [Numeric] seconds to wait for each expected output
    # @param exec [Boolean, nil] run commands on exec channels when the transport supports it; the dialect decides when nil
    # @param interactions [Array<Dialect::Interaction>] responders tried after the dialect's own
    # @param progress [Proc] receives a message when connecting and whenever waiting for the device
    # @param secrets [SecretsResolver] reads the node's password and secrets
    #: (node: Proto::V1::Node, ?transport: Transports::Base?, ?timeout: Numeric, ?exec: bool?, ?interactions: Array[Dialect::Interaction], ?progress: ^(String) -> void, ?secrets: SecretsResolver) -> void
    def initialize(node:, transport: nil, timeout: CliSession::DEFAULT_TIMEOUT, exec: nil, interactions: [], progress: ->(_message) {}, secrets: SecretsResolver.new)
      @node = node #: Proto::V1::Node
      @secrets = secrets #: SecretsResolver
      @progress = progress #: ^(String) -> void
      @dialect = Dialects.find(node.dialect) #: singleton(Dialects::Base)
      @kind = (node.transport.empty? ? DEFAULT_TRANSPORT : node.transport) #: String
      @transport = transport || build_transport #: Transports::Base
      @config = @dialect.communication_config(@kind.to_sym) #: Dialect::CommunicationConfig
      @exec = (exec.nil? ? @config.exec : exec) #: bool
      @cli = CliSession.new(
        transport: @transport,
        prompt: @dialect.prompt_pattern,
        data_filters: @dialect.data_filters,
        interactions: @dialect.interactions + interactions,
        exec: @exec,
        timeout:,
        progress:,
      ) #: CliSession
      @run = Dialect::Run.new(cli: @cli, node:, dialect: @dialect, secrets:) #: Dialect::Run
    end

    #: Proto::V1::Node
    attr_reader :node
    #: singleton(Dialects::Base)
    attr_reader :dialect
    # @return [Transports::Base] underlying transport
    #: Transports::Base
    attr_reader :transport
    # @return [CliSession] session to the node
    #: CliSession
    attr_reader :cli
    # @return [Dialect::Run] run state passed to runbooks and hooks
    #: Dialect::Run
    attr_reader :run

    # Connects, logs in and runs the post-login hooks. The connection is
    # closed when any of them fails.
    #
    # @return [void]
    # @raise [TimeoutError] when the device does not answer as the dialect expects
    # @raise [ConnectionClosed] when the device drops the connection
    #: () -> void
    def open
      @transport.pty_options = @config.pty_options
      @progress.call("connecting to #{@transport.host} over #{@kind}")
      @transport.open
      begin
        login unless exec_only?
        @config.post_login_hooks.each { it.call(run) }
      rescue StandardError
        close
        raise
      end
    end

    # Runs the pre-logout hooks.
    #
    # @return [void]
    #: () -> void
    def logout
      @config.pre_logout_hooks.each { it.call(run) }
    end

    # Closes the connection without logging out. Safe to call more than once.
    #
    # @return [void]
    #: () -> void
    def close
      @transport.close
    end

    # @return [Boolean] whether every command runs on exec channels, so the shell is never used
    #: () -> bool
    private def exec_only? = @exec && @transport.exec?

    # Answers login prompts the dialect declares until the first prompt appears.
    # Each login prompt is answered at most once, and none has to appear, as
    # some devices ask for credentials only under certain settings.
    #
    # @return [void]
    #: () -> void
    private def login
      answers = {} #: Hash[Regexp, ^() -> String?]
      if (username_prompt = @config.username_prompt)
        answers[username_prompt] = -> { node.username }
      end
      if (password_prompt = @config.password_prompt)
        answers[password_prompt] = -> { @secrets.maybe(node.password)&.value }
      end
      # Sorbet cannot check a splat against expect's keyword options (7019).
      cli = @cli #: as untyped
      loop do
        answer = answers.delete(cli.expect(*answers.keys, @cli.prompt).regexp)
        return unless answer

        @cli.write("#{answer.call}\n")
      end
    end

    # @return [Transports::Base] transport built from the node
    # @raise [Finder::NotFound] when the transport is unknown
    #: () -> Transports::Base
    private def build_transport
      Transports.find(@kind).new(
        host: node.host.empty? ? node.name : node.host,
        port: node.port.zero? ? nil : node.port,
        username: node.username,
        password: @secrets.maybe(node.password),
        transport_options: node.transport_options,
        secrets: @secrets,
      )
    end
  end
end
