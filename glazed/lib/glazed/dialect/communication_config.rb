# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialect'

module Glazed
  module Dialect
    # How a dialect talks to a device over one transport.
    class CommunicationConfig
      #: type hook = ^(Run run) -> void

      #: () -> void
      def initialize
        @exec = false #: bool
        @username_prompt = nil #: Regexp?
        @password_prompt = nil #: Regexp?
        @post_login_hooks = [] #: Array[CommunicationConfig::hook]
        @pre_logout_hooks = [] #: Array[CommunicationConfig::hook]
      end

      # @return [Boolean] run each command on its own exec channel when the transport supports it
      #: bool
      attr_accessor :exec
      # @return [Regexp, nil] prompt for the user name; when set, the session logs in by answering it
      #: Regexp?
      attr_accessor :username_prompt
      # @return [Regexp, nil] prompt for the password
      #: Regexp?
      attr_accessor :password_prompt
      # @return [Array<Proc>] hooks run after login, in order
      #: Array[CommunicationConfig::hook]
      attr_reader :post_login_hooks
      # @return [Array<Proc>] hooks run before logout, in order
      #: Array[CommunicationConfig::hook]
      attr_reader :pre_logout_hooks

      # Adds a hook run after login and before the runbook.
      #
      # @yieldparam run [Run] the run in progress
      # @return [void]
      #: () { (Run run) -> void } -> void
      def post_login(&hook)
        @post_login_hooks << hook
      end

      # Adds a hook run after the runbook and before the connection closes.
      #
      # @yieldparam run [Run] the run in progress
      # @return [void]
      #: () { (Run run) -> void } -> void
      def pre_logout(&hook)
        @pre_logout_hooks << hook
      end
    end
  end
end
