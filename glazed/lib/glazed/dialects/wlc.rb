# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

# Derived from Oxidized (https://github.com/ytti/oxidized) lib/oxidized/model/aireos.rb,
# Copyright 2013-2015 Saku Ytti, Samer Abdel-Hafez and Oxidized contributors,
# licensed under the Apache License, Version 2.0. Modified for the glazed dialect API.

require 'glazed/dialects/base'

module Glazed
  module Dialects
    # Cisco Wireless LAN Controller on AireOS. Ported from oxidized's aireos model.
    #
    # AireOS asks for the user name and password inside the session, after SSH
    # authentication as well.
    class Wlc < Base
      prompt(/^\([^)]+\)\s>/)
      comment_prefix '# '

      sensitive_pattern(/^config snmp community create (\S+)/) { it[1] }
      sensitive_pattern(/^config wlan security wpa akm psk set-key (?:ascii|hex) (\S+)/) { it[1] }
      sensitive_pattern(/^config (?:radius|tacacs) (?:auth|acct|athr) add \d+ \S+ \d+ (?:ascii|hex) (\S+)/) { it[1] }

      runbook :get do |book|
        book.command('show udi') { comment("#{clean(it.output)}\n") }
        book.command('show boot') { comment("#{clean(it.output)}\n") }
        book.command('show run-config commands') { clean(it.output) }
      end

      communication :ssh, :telnet do |config|
        config.username_prompt = /^User:\s*/
        config.password_prompt = /^Password:\s*/
        config.post_login { |run| run.cli.command('config paging disable') }
        # Logout asks whether to save unsaved changes.
        config.pre_logout do |run|
          run.cli.write("logout\n")
          run.cli.write('n')
        end
      end

      # Drops blank lines, rogue alerts and surrounding spaces.
      #
      # @param output [String] command output
      # @return [String] cleaned lines, ending with a newline
      #: (String output) -> String
      def self.clean(output)
        lines = output.each_line.map(&:strip).reject do |line|
          line.empty? || line.match?(/rogue (adhoc|client) (alert|Unknown) [\da-f]{2}:/)
        end
        "#{lines.join("\n")}\n"
      end
    end
  end
end
