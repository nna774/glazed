# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/oxidized/errors'
require 'glazed/proto'
require 'glazed/secrets_resolver'

module Glazed
  module Oxidized
    # A glazed node as an Oxidized model sees it through `@node` and `vars`.
    #
    # Variables are the node's params, with "true" and "false" read as
    # booleans, and its secrets, resolved on first use.
    class NodeView
      # @param node [Proto::V1::Node] node being collected
      # @param prompt [Regexp] prompt pattern of the dialect
      # @param secrets [SecretsResolver] reads the node's password and secrets
      #: (node: Proto::V1::Node, prompt: Regexp, secrets: SecretsResolver) -> void
      def initialize(node:, prompt:, secrets:)
        @node = node #: Proto::V1::Node
        @prompt = prompt #: Regexp
        @secrets = secrets #: SecretsResolver
        @vars = nil #: Hash[Symbol, untyped]?
      end

      # @return [Regexp] prompt pattern of the dialect
      #: Regexp
      attr_reader :prompt

      # @return [String] node name
      #: () -> String
      def name = @node.name

      # @return [String] address connected to
      #: () -> String
      def ip = @node.host.empty? ? @node.name : @node.host

      # @return [String] node group
      #: () -> String
      def group = @node.group

      # @return [Hash{Symbol => String, nil}] login credentials
      # @raise [Secret::Unavailable] when the password cannot be read
      #: () -> Hash[Symbol, String?]
      def auth = {username: @node.username, password: @secrets.maybe(@node.password)&.value}

      # @return [Hash{Symbol => Object}] params and secrets of the node
      # @raise [Secret::Unavailable] when a secret cannot be read
      #: () -> Hash[Symbol, untyped]
      def vars
        @vars ||= {}.tap do |vars|
          @node.params.each { |key, value| vars[key.to_sym] = cast(value) }
          @node.secrets.each { |key, ref| vars[key.to_sym] = @secrets.value(ref) }
        end
      end

      # @param value [String] param value
      # @return [String, Boolean] booleans for "true" and "false", the value otherwise
      #: (String value) -> (String | bool)
      private def cast(value)
        case value
        when 'true' then true
        when 'false' then false
        else value
        end
      end
    end
  end
end
